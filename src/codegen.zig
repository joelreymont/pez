//! Python source code generation from AST.
//!
//! Converts AST nodes back into Python source code.

const std = @import("std");
const ast = @import("ast.zig");
const pyc = @import("pyc.zig");

pub const Expr = ast.Expr;
pub const Stmt = ast.Stmt;
pub const Constant = ast.Constant;
pub const BinOp = ast.BinOp;
pub const UnaryOp = ast.UnaryOp;
pub const CmpOp = ast.CmpOp;
pub const BoolOp = ast.BoolOp;

/// Python source code writer.
pub const Writer = struct {
    output: std.ArrayList(u8),
    indent_level: u32,
    indent_str: []const u8,

    pub fn init(_: std.mem.Allocator) Writer {
        return .{
            .output = .{},
            .indent_level = 0,
            .indent_str = "    ",
        };
    }

    pub fn deinit(self: *Writer, allocator: std.mem.Allocator) void {
        self.output.deinit(allocator);
    }

    pub fn getOutput(self: *Writer, allocator: std.mem.Allocator) ![]const u8 {
        return self.output.toOwnedSlice(allocator);
    }

    fn write(self: *Writer, allocator: std.mem.Allocator, data: []const u8) !void {
        try self.output.appendSlice(allocator, data);
    }

    fn writeByte(self: *Writer, allocator: std.mem.Allocator, byte: u8) !void {
        try self.output.append(allocator, byte);
    }

    fn writeIndent(self: *Writer, allocator: std.mem.Allocator) !void {
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.write(allocator, self.indent_str);
        }
    }

    fn writeFmt(self: *Writer, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, fmt, args) catch {
            // If buffer is too small, allocate
            const str = try std.fmt.allocPrint(allocator, fmt, args);
            defer allocator.free(str);
            try self.write(allocator, str);
            return;
        };
        try self.write(allocator, result);
    }

    pub const WriteError = std.mem.Allocator.Error;

    /// Write an expression with operator precedence handling.
    pub fn writeExpr(self: *Writer, allocator: std.mem.Allocator, expr: *const Expr) WriteError!void {
        try self.writeExprPrec(allocator, expr, 0);
    }

    /// Write an expression, adding parentheses if needed based on precedence.
    fn writeExprPrec(self: *Writer, allocator: std.mem.Allocator, expr: *const Expr, parent_prec: u8) WriteError!void {
        switch (expr.*) {
            .constant => |c| try self.writeConstant(allocator, c),
            .name => |n| try self.write(allocator, n.id),
            .bin_op => |b| {
                const prec = b.op.precedence();
                const needs_parens = prec < parent_prec;
                if (needs_parens) try self.writeByte(allocator, '(');
                try self.writeExprPrec(allocator, b.left, prec);
                try self.write(allocator, " ");
                try self.write(allocator, b.op.symbol());
                try self.write(allocator, " ");
                try self.writeExprPrec(allocator, b.right, prec + 1); // +1 for left-associativity
                if (needs_parens) try self.writeByte(allocator, ')');
            },
            .unary_op => |u| {
                try self.write(allocator, u.op.symbol());
                try self.writeExprPrec(allocator, u.operand, 14); // Unary has high precedence
            },
            .compare => |c| {
                try self.writeExprPrec(allocator, c.left, 0);
                for (c.ops, c.comparators) |op, cmp| {
                    try self.write(allocator, " ");
                    try self.write(allocator, op.symbol());
                    try self.write(allocator, " ");
                    try self.writeExprPrec(allocator, cmp, 0);
                }
            },
            .bool_op => |b| {
                const prec: u8 = if (b.op == .and_) 4 else 3;
                const needs_parens = prec < parent_prec;
                if (needs_parens) try self.writeByte(allocator, '(');
                for (b.values, 0..) |v, i| {
                    if (i > 0) {
                        try self.write(allocator, " ");
                        try self.write(allocator, b.op.symbol());
                        try self.write(allocator, " ");
                    }
                    try self.writeExprPrec(allocator, v, prec);
                }
                if (needs_parens) try self.writeByte(allocator, ')');
            },
            .if_exp => |i| {
                // Ternary: body if condition else else_body
                try self.writeExprPrec(allocator, i.body, 0);
                try self.write(allocator, " if ");
                try self.writeExprPrec(allocator, i.condition, 0);
                try self.write(allocator, " else ");
                try self.writeExprPrec(allocator, i.else_body, 0);
            },
            .call => |c| {
                try self.writeExprPrec(allocator, c.func, 15);
                try self.writeByte(allocator, '(');
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.writeExpr(allocator, arg);
                }
                for (c.keywords, 0..) |kw, i| {
                    if (i > 0 or c.args.len > 0) try self.write(allocator, ", ");
                    if (kw.arg) |arg| {
                        try self.write(allocator, arg);
                        try self.writeByte(allocator, '=');
                    } else {
                        try self.write(allocator, "**");
                    }
                    try self.writeExpr(allocator, kw.value);
                }
                try self.writeByte(allocator, ')');
            },
            .attribute => |a| {
                try self.writeExprPrec(allocator, a.value, 15);
                try self.writeByte(allocator, '.');
                try self.write(allocator, a.attr);
            },
            .subscript => |s| {
                try self.writeExprPrec(allocator, s.value, 15);
                try self.writeByte(allocator, '[');
                try self.writeExpr(allocator, s.slice);
                try self.writeByte(allocator, ']');
            },
            .slice => |s| {
                if (s.lower) |l| try self.writeExpr(allocator, l);
                try self.writeByte(allocator, ':');
                if (s.upper) |u| try self.writeExpr(allocator, u);
                if (s.step) |step| {
                    try self.writeByte(allocator, ':');
                    try self.writeExpr(allocator, step);
                }
            },
            .list => |l| {
                try self.writeByte(allocator, '[');
                for (l.elts, 0..) |e, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.writeExpr(allocator, e);
                }
                try self.writeByte(allocator, ']');
            },
            .tuple => |t| {
                try self.writeByte(allocator, '(');
                for (t.elts, 0..) |e, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.writeExpr(allocator, e);
                }
                if (t.elts.len == 1) try self.writeByte(allocator, ',');
                try self.writeByte(allocator, ')');
            },
            .set => |s| {
                try self.writeByte(allocator, '{');
                for (s.elts, 0..) |e, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.writeExpr(allocator, e);
                }
                try self.writeByte(allocator, '}');
            },
            .dict => |d| {
                try self.writeByte(allocator, '{');
                for (d.keys, d.values, 0..) |k, v, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    if (k) |key| {
                        try self.writeExpr(allocator, key);
                        try self.write(allocator, ": ");
                    } else {
                        try self.write(allocator, "**");
                    }
                    try self.writeExpr(allocator, v);
                }
                try self.writeByte(allocator, '}');
            },
            .starred => |s| {
                try self.writeByte(allocator, '*');
                try self.writeExpr(allocator, s.value);
            },
            .formatted_value => |f| {
                try self.writeByte(allocator, '{');
                try self.writeExpr(allocator, f.value);
                if (f.conversion) |c| {
                    try self.writeByte(allocator, '!');
                    try self.writeByte(allocator, c);
                }
                if (f.format_spec) |spec| {
                    try self.writeByte(allocator, ':');
                    try self.writeExpr(allocator, spec);
                }
                try self.writeByte(allocator, '}');
            },
            .joined_str => |j| {
                try self.write(allocator, "f\"");
                for (j.values) |v| {
                    switch (v.*) {
                        .constant => |c| {
                            if (c == .string) {
                                try self.writeStringContents(allocator, c.string);
                            }
                        },
                        else => try self.writeExpr(allocator, v),
                    }
                }
                try self.writeByte(allocator, '"');
            },
            .await_expr => |a| {
                try self.write(allocator, "await ");
                try self.writeExpr(allocator, a.value);
            },
            .yield_expr => |y| {
                try self.write(allocator, "yield");
                if (y.value) |v| {
                    try self.writeByte(allocator, ' ');
                    try self.writeExpr(allocator, v);
                }
            },
            .yield_from => |y| {
                try self.write(allocator, "yield from ");
                try self.writeExpr(allocator, y.value);
            },
            .lambda => |l| {
                try self.write(allocator, "lambda");
                try self.writeArguments(allocator, l.args);
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, l.body);
            },
            else => {
                try self.write(allocator, "<?>");
            },
        }
    }

    fn writeConstant(self: *Writer, allocator: std.mem.Allocator, c: Constant) !void {
        switch (c) {
            .none => try self.write(allocator, "None"),
            .true_ => try self.write(allocator, "True"),
            .false_ => try self.write(allocator, "False"),
            .ellipsis => try self.write(allocator, "..."),
            .int => |v| try self.writeFmt(allocator, "{d}", .{v}),
            .float => |v| try self.writeFmt(allocator, "{d}", .{v}),
            .complex => |v| {
                if (v.real != 0) {
                    try self.writeFmt(allocator, "({d}", .{v.real});
                    if (v.imag >= 0) {
                        try self.writeFmt(allocator, "+{d}j)", .{v.imag});
                    } else {
                        try self.writeFmt(allocator, "{d}j)", .{v.imag});
                    }
                } else {
                    try self.writeFmt(allocator, "{d}j", .{v.imag});
                }
            },
            .string => |s| {
                try self.writeByte(allocator, '"');
                try self.writeStringContents(allocator, s);
                try self.writeByte(allocator, '"');
            },
            .bytes => |b| {
                try self.write(allocator, "b\"");
                try self.writeStringContents(allocator, b);
                try self.writeByte(allocator, '"');
            },
        }
    }

    fn writeStringContents(self: *Writer, allocator: std.mem.Allocator, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '\n' => try self.write(allocator, "\\n"),
                '\r' => try self.write(allocator, "\\r"),
                '\t' => try self.write(allocator, "\\t"),
                '\\' => try self.write(allocator, "\\\\"),
                '"' => try self.write(allocator, "\\\""),
                else => {
                    if (c >= 0x20 and c < 0x7F) {
                        try self.writeByte(allocator, c);
                    } else {
                        try self.writeFmt(allocator, "\\x{x:0>2}", .{c});
                    }
                },
            }
        }
    }

    fn writeArguments(self: *Writer, allocator: std.mem.Allocator, args: *const ast.Arguments) !void {
        var first = true;

        // Write positional-only args
        for (args.posonlyargs) |arg| {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, arg.arg);
        }

        if (args.posonlyargs.len > 0) {
            try self.write(allocator, ", /");
        }

        // Write regular args
        for (args.args) |arg| {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, arg.arg);
        }

        // Write *args
        if (args.vararg) |va| {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, "*");
            try self.write(allocator, va.arg);
        }

        // Write keyword-only args
        for (args.kwonlyargs) |arg| {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, arg.arg);
        }

        // Write **kwargs
        if (args.kwarg) |kw| {
            if (!first) try self.write(allocator, ", ");
            try self.write(allocator, "**");
            try self.write(allocator, kw.arg);
        }
    }

    /// Write a statement.
    pub fn writeStmt(self: *Writer, allocator: std.mem.Allocator, stmt: *const Stmt) !void {
        try self.writeIndent(allocator);

        switch (stmt.*) {
            .expr_stmt => |e| {
                try self.writeExpr(allocator, e.value);
                try self.writeByte(allocator, '\n');
            },
            .return_stmt => |r| {
                try self.write(allocator, "return");
                if (r.value) |v| {
                    try self.writeByte(allocator, ' ');
                    try self.writeExpr(allocator, v);
                }
                try self.writeByte(allocator, '\n');
            },
            .assign => |a| {
                for (a.targets, 0..) |t, i| {
                    if (i > 0) try self.write(allocator, " = ");
                    try self.writeExpr(allocator, t);
                }
                try self.write(allocator, " = ");
                try self.writeExpr(allocator, a.value);
                try self.writeByte(allocator, '\n');
            },
            .aug_assign => |a| {
                try self.writeExpr(allocator, a.target);
                try self.write(allocator, " ");
                try self.write(allocator, a.op.symbol());
                try self.write(allocator, "= ");
                try self.writeExpr(allocator, a.value);
                try self.writeByte(allocator, '\n');
            },
            .if_stmt => |i| {
                try self.write(allocator, "if ");
                try self.writeExpr(allocator, i.condition);
                try self.write(allocator, ":\n");
                self.indent_level += 1;
                for (i.body) |s| {
                    try self.writeStmt(allocator, s);
                }
                self.indent_level -= 1;
                if (i.else_body.len > 0) {
                    try self.writeIndent(allocator);
                    // Check if else body is a single if statement (elif)
                    if (i.else_body.len == 1 and i.else_body[0].* == .if_stmt) {
                        try self.write(allocator, "el");
                        // Remove indent for elif
                        try self.writeStmt(allocator, i.else_body[0]);
                    } else {
                        try self.write(allocator, "else:\n");
                        self.indent_level += 1;
                        for (i.else_body) |s| {
                            try self.writeStmt(allocator, s);
                        }
                        self.indent_level -= 1;
                    }
                }
            },
            .while_stmt => |w| {
                try self.write(allocator, "while ");
                try self.writeExpr(allocator, w.condition);
                try self.write(allocator, ":\n");
                self.indent_level += 1;
                for (w.body) |s| {
                    try self.writeStmt(allocator, s);
                }
                self.indent_level -= 1;
                if (w.else_body.len > 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "else:\n");
                    self.indent_level += 1;
                    for (w.else_body) |s| {
                        try self.writeStmt(allocator, s);
                    }
                    self.indent_level -= 1;
                }
            },
            .for_stmt => |f| {
                if (f.is_async) try self.write(allocator, "async ");
                try self.write(allocator, "for ");
                try self.writeExpr(allocator, f.target);
                try self.write(allocator, " in ");
                try self.writeExpr(allocator, f.iter);
                try self.write(allocator, ":\n");
                self.indent_level += 1;
                for (f.body) |s| {
                    try self.writeStmt(allocator, s);
                }
                self.indent_level -= 1;
                if (f.else_body.len > 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "else:\n");
                    self.indent_level += 1;
                    for (f.else_body) |s| {
                        try self.writeStmt(allocator, s);
                    }
                    self.indent_level -= 1;
                }
            },
            .pass => {
                try self.write(allocator, "pass\n");
            },
            .break_stmt => {
                try self.write(allocator, "break\n");
            },
            .continue_stmt => {
                try self.write(allocator, "continue\n");
            },
            .function_def => |f| {
                for (f.decorator_list) |d| {
                    try self.write(allocator, "@");
                    try self.writeExpr(allocator, d);
                    try self.writeByte(allocator, '\n');
                    try self.writeIndent(allocator);
                }
                if (f.is_async) try self.write(allocator, "async ");
                try self.write(allocator, "def ");
                try self.write(allocator, f.name);
                try self.writeByte(allocator, '(');
                try self.writeArguments(allocator, f.args);
                try self.writeByte(allocator, ')');
                if (f.returns) |r| {
                    try self.write(allocator, " -> ");
                    try self.writeExpr(allocator, r);
                }
                try self.write(allocator, ":\n");
                self.indent_level += 1;
                if (f.body.len == 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "pass\n");
                } else {
                    for (f.body) |s| {
                        try self.writeStmt(allocator, s);
                    }
                }
                self.indent_level -= 1;
            },
            .class_def => |c| {
                for (c.decorator_list) |d| {
                    try self.write(allocator, "@");
                    try self.writeExpr(allocator, d);
                    try self.writeByte(allocator, '\n');
                    try self.writeIndent(allocator);
                }
                try self.write(allocator, "class ");
                try self.write(allocator, c.name);
                if (c.bases.len > 0 or c.keywords.len > 0) {
                    try self.writeByte(allocator, '(');
                    for (c.bases, 0..) |b, i| {
                        if (i > 0) try self.write(allocator, ", ");
                        try self.writeExpr(allocator, b);
                    }
                    for (c.keywords, 0..) |kw, i| {
                        if (i > 0 or c.bases.len > 0) try self.write(allocator, ", ");
                        if (kw.arg) |arg| {
                            try self.write(allocator, arg);
                            try self.writeByte(allocator, '=');
                        }
                        try self.writeExpr(allocator, kw.value);
                    }
                    try self.writeByte(allocator, ')');
                }
                try self.write(allocator, ":\n");
                self.indent_level += 1;
                if (c.body.len == 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "pass\n");
                } else {
                    for (c.body) |s| {
                        try self.writeStmt(allocator, s);
                    }
                }
                self.indent_level -= 1;
            },
            .import_stmt => |i| {
                try self.write(allocator, "import ");
                for (i.names, 0..) |name, idx| {
                    if (idx > 0) try self.write(allocator, ", ");
                    try self.write(allocator, name.name);
                    if (name.asname) |as| {
                        try self.write(allocator, " as ");
                        try self.write(allocator, as);
                    }
                }
                try self.writeByte(allocator, '\n');
            },
            .import_from => |i| {
                try self.write(allocator, "from ");
                var dots: u32 = 0;
                while (dots < i.level) : (dots += 1) {
                    try self.writeByte(allocator, '.');
                }
                if (i.module) |m| {
                    try self.write(allocator, m);
                }
                try self.write(allocator, " import ");
                for (i.names, 0..) |name, idx| {
                    if (idx > 0) try self.write(allocator, ", ");
                    try self.write(allocator, name.name);
                    if (name.asname) |as| {
                        try self.write(allocator, " as ");
                        try self.write(allocator, as);
                    }
                }
                try self.writeByte(allocator, '\n');
            },
            .raise_stmt => |r| {
                try self.write(allocator, "raise");
                if (r.exc) |e| {
                    try self.writeByte(allocator, ' ');
                    try self.writeExpr(allocator, e);
                    if (r.cause) |c| {
                        try self.write(allocator, " from ");
                        try self.writeExpr(allocator, c);
                    }
                }
                try self.writeByte(allocator, '\n');
            },
            .global_stmt => |g| {
                try self.write(allocator, "global ");
                for (g.names, 0..) |n, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.write(allocator, n);
                }
                try self.writeByte(allocator, '\n');
            },
            .nonlocal_stmt => |n| {
                try self.write(allocator, "nonlocal ");
                for (n.names, 0..) |name, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.write(allocator, name);
                }
                try self.writeByte(allocator, '\n');
            },
            .delete => |d| {
                try self.write(allocator, "del ");
                for (d.targets, 0..) |t, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.writeExpr(allocator, t);
                }
                try self.writeByte(allocator, '\n');
            },
            .assert_stmt => |a| {
                try self.write(allocator, "assert ");
                try self.writeExpr(allocator, a.condition);
                if (a.msg) |m| {
                    try self.write(allocator, ", ");
                    try self.writeExpr(allocator, m);
                }
                try self.writeByte(allocator, '\n');
            },
            else => {
                try self.write(allocator, "# <unsupported statement>\n");
            },
        }
    }
};

test "codegen constant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var writer = Writer.init(allocator);
    defer writer.deinit(allocator);

    const expr = try ast.makeConstant(allocator, .{ .int = 42 });
    defer {
        @constCast(expr).deinit(allocator);
        allocator.destroy(expr);
    }

    try writer.writeExpr(allocator, expr);
    const output = try writer.getOutput(allocator);
    defer allocator.free(output);

    try testing.expectEqualStrings("42", output);
}

test "codegen binop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var writer = Writer.init(allocator);
    defer writer.deinit(allocator);

    const left = try ast.makeConstant(allocator, .{ .int = 1 });
    const right = try ast.makeConstant(allocator, .{ .int = 2 });
    const binop = try ast.makeBinOp(allocator, left, .add, right);
    defer {
        @constCast(binop).deinit(allocator);
        allocator.destroy(binop);
    }

    try writer.writeExpr(allocator, binop);
    const output = try writer.getOutput(allocator);
    defer allocator.free(output);

    try testing.expectEqualStrings("1 + 2", output);
}

test "codegen string escaping" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var writer = Writer.init(allocator);
    defer writer.deinit(allocator);

    const expr = try ast.makeConstant(allocator, .{ .string = "hello\nworld" });
    defer allocator.destroy(expr);

    try writer.writeExpr(allocator, expr);
    const output = try writer.getOutput(allocator);
    defer allocator.free(output);

    try testing.expectEqualStrings("\"hello\\nworld\"", output);
}

// ============================================================================
// AST Debug Pretty Printer
// ============================================================================

/// Debug printer that shows AST structure with indentation.
pub const DebugPrinter = struct {
    indent_level: u32 = 0,
    indent_str: []const u8 = "  ",

    /// Print an expression tree to a writer.
    pub fn printExpr(self: *DebugPrinter, w: anytype, expr: *const Expr) !void {
        try self.writeIndent(w);
        switch (expr.*) {
            .constant => |c| {
                try w.writeAll("Constant(");
                try self.printConstant(w, c);
                try w.writeAll(")\n");
            },
            .name => |n| {
                try w.print("Name(\"{s}\", {s})\n", .{ n.id, @tagName(n.ctx) });
            },
            .bin_op => |b| {
                try w.print("BinOp({s})\n", .{b.op.symbol()});
                self.indent_level += 1;
                try self.printExpr(w, b.left);
                try self.printExpr(w, b.right);
                self.indent_level -= 1;
            },
            .unary_op => |u| {
                try w.print("UnaryOp({s})\n", .{@tagName(u.op)});
                self.indent_level += 1;
                try self.printExpr(w, u.operand);
                self.indent_level -= 1;
            },
            .compare => |c| {
                try w.writeAll("Compare(");
                for (c.ops, 0..) |op, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(op.symbol());
                }
                try w.writeAll(")\n");
                self.indent_level += 1;
                try self.printExpr(w, c.left);
                for (c.comparators) |cmp| {
                    try self.printExpr(w, cmp);
                }
                self.indent_level -= 1;
            },
            .bool_op => |b| {
                try w.print("BoolOp({s})\n", .{b.op.symbol()});
                self.indent_level += 1;
                for (b.values) |v| {
                    try self.printExpr(w, v);
                }
                self.indent_level -= 1;
            },
            .call => |c| {
                try w.print("Call(argc={d})\n", .{c.args.len});
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("func:\n");
                self.indent_level += 1;
                try self.printExpr(w, c.func);
                self.indent_level -= 1;
                if (c.args.len > 0) {
                    try self.writeIndent(w);
                    try w.writeAll("args:\n");
                    self.indent_level += 1;
                    for (c.args) |arg| {
                        try self.printExpr(w, arg);
                    }
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
            },
            .attribute => |a| {
                try w.print("Attribute(\"{s}\", {s})\n", .{ a.attr, @tagName(a.ctx) });
                self.indent_level += 1;
                try self.printExpr(w, a.value);
                self.indent_level -= 1;
            },
            .subscript => |s| {
                try w.print("Subscript({s})\n", .{@tagName(s.ctx)});
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("value:\n");
                self.indent_level += 1;
                try self.printExpr(w, s.value);
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.writeAll("slice:\n");
                self.indent_level += 1;
                try self.printExpr(w, s.slice);
                self.indent_level -= 1;
                self.indent_level -= 1;
            },
            .list => |l| {
                try w.print("List(len={d})\n", .{l.elts.len});
                self.indent_level += 1;
                for (l.elts) |e| {
                    try self.printExpr(w, e);
                }
                self.indent_level -= 1;
            },
            .tuple => |t| {
                try w.print("Tuple(len={d})\n", .{t.elts.len});
                self.indent_level += 1;
                for (t.elts) |e| {
                    try self.printExpr(w, e);
                }
                self.indent_level -= 1;
            },
            .set => |s| {
                try w.print("Set(len={d})\n", .{s.elts.len});
                self.indent_level += 1;
                for (s.elts) |e| {
                    try self.printExpr(w, e);
                }
                self.indent_level -= 1;
            },
            .dict => |d| {
                try w.print("Dict(len={d})\n", .{d.keys.len});
                self.indent_level += 1;
                for (d.keys, d.values) |k, v| {
                    try self.writeIndent(w);
                    if (k) |key| {
                        try w.writeAll("key:\n");
                        self.indent_level += 1;
                        try self.printExpr(w, key);
                        self.indent_level -= 1;
                    } else {
                        try w.writeAll("**spread\n");
                    }
                    try self.writeIndent(w);
                    try w.writeAll("value:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, v);
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
            },
            .if_exp => |i| {
                try w.writeAll("IfExp\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("condition:\n");
                self.indent_level += 1;
                try self.printExpr(w, i.condition);
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.writeAll("body:\n");
                self.indent_level += 1;
                try self.printExpr(w, i.body);
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.writeAll("else:\n");
                self.indent_level += 1;
                try self.printExpr(w, i.else_body);
                self.indent_level -= 1;
                self.indent_level -= 1;
            },
            .slice => |s| {
                try w.writeAll("Slice\n");
                self.indent_level += 1;
                if (s.lower) |l| {
                    try self.writeIndent(w);
                    try w.writeAll("lower:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, l);
                    self.indent_level -= 1;
                }
                if (s.upper) |u| {
                    try self.writeIndent(w);
                    try w.writeAll("upper:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, u);
                    self.indent_level -= 1;
                }
                if (s.step) |step| {
                    try self.writeIndent(w);
                    try w.writeAll("step:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, step);
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
            },
            .lambda => |l| {
                try w.writeAll("Lambda\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("body:\n");
                self.indent_level += 1;
                try self.printExpr(w, l.body);
                self.indent_level -= 1;
                self.indent_level -= 1;
            },
            .await_expr => |a| {
                try w.writeAll("Await\n");
                self.indent_level += 1;
                try self.printExpr(w, a.value);
                self.indent_level -= 1;
            },
            .yield_expr => |y| {
                try w.writeAll("Yield\n");
                if (y.value) |v| {
                    self.indent_level += 1;
                    try self.printExpr(w, v);
                    self.indent_level -= 1;
                }
            },
            .yield_from => |y| {
                try w.writeAll("YieldFrom\n");
                self.indent_level += 1;
                try self.printExpr(w, y.value);
                self.indent_level -= 1;
            },
            .starred => |s| {
                try w.writeAll("Starred\n");
                self.indent_level += 1;
                try self.printExpr(w, s.value);
                self.indent_level -= 1;
            },
            else => {
                try w.print("<{s}>\n", .{@tagName(expr.*)});
            },
        }
    }

    fn printConstant(self: *DebugPrinter, w: anytype, c: Constant) !void {
        _ = self;
        switch (c) {
            .none => try w.writeAll("None"),
            .true_ => try w.writeAll("True"),
            .false_ => try w.writeAll("False"),
            .ellipsis => try w.writeAll("..."),
            .int => |v| try w.print("{d}", .{v}),
            .float => |v| try w.print("{d}", .{v}),
            .complex => |v| try w.print("{d}+{d}j", .{ v.real, v.imag }),
            .string => |s| try w.print("\"{s}\"", .{s}),
            .bytes => |b| try w.print("b\"{s}\"", .{b}),
        }
    }

    fn writeIndent(self: *DebugPrinter, w: anytype) !void {
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) {
            try w.writeAll(self.indent_str);
        }
    }

    /// Print a statement tree to a writer.
    pub fn printStmt(self: *DebugPrinter, w: anytype, stmt: *const Stmt) !void {
        try self.writeIndent(w);
        switch (stmt.*) {
            .expr_stmt => |e| {
                try w.writeAll("ExprStmt\n");
                self.indent_level += 1;
                try self.printExpr(w, e.value);
                self.indent_level -= 1;
            },
            .return_stmt => |r| {
                try w.writeAll("Return\n");
                if (r.value) |v| {
                    self.indent_level += 1;
                    try self.printExpr(w, v);
                    self.indent_level -= 1;
                }
            },
            .assign => |a| {
                try w.print("Assign(targets={d})\n", .{a.targets.len});
                self.indent_level += 1;
                for (a.targets) |t| {
                    try self.printExpr(w, t);
                }
                try self.writeIndent(w);
                try w.writeAll("value:\n");
                self.indent_level += 1;
                try self.printExpr(w, a.value);
                self.indent_level -= 1;
                self.indent_level -= 1;
            },
            .if_stmt => |i| {
                try w.writeAll("If\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("condition:\n");
                self.indent_level += 1;
                try self.printExpr(w, i.condition);
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.print("body({d}):\n", .{i.body.len});
                self.indent_level += 1;
                for (i.body) |s| {
                    try self.printStmt(w, s);
                }
                self.indent_level -= 1;
                if (i.else_body.len > 0) {
                    try self.writeIndent(w);
                    try w.print("else({d}):\n", .{i.else_body.len});
                    self.indent_level += 1;
                    for (i.else_body) |s| {
                        try self.printStmt(w, s);
                    }
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
            },
            .while_stmt => |ws| {
                try w.writeAll("While\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("condition:\n");
                self.indent_level += 1;
                try self.printExpr(w, ws.condition);
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.print("body({d}):\n", .{ws.body.len});
                self.indent_level += 1;
                for (ws.body) |s| {
                    try self.printStmt(w, s);
                }
                self.indent_level -= 1;
                self.indent_level -= 1;
            },
            .for_stmt => |f| {
                if (f.is_async) {
                    try w.writeAll("AsyncFor\n");
                } else {
                    try w.writeAll("For\n");
                }
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("target:\n");
                self.indent_level += 1;
                try self.printExpr(w, f.target);
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.writeAll("iter:\n");
                self.indent_level += 1;
                try self.printExpr(w, f.iter);
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.print("body({d}):\n", .{f.body.len});
                self.indent_level += 1;
                for (f.body) |s| {
                    try self.printStmt(w, s);
                }
                self.indent_level -= 1;
                self.indent_level -= 1;
            },
            .function_def => |f| {
                if (f.is_async) {
                    try w.print("AsyncFunctionDef(\"{s}\")\n", .{f.name});
                } else {
                    try w.print("FunctionDef(\"{s}\")\n", .{f.name});
                }
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.print("body({d}):\n", .{f.body.len});
                self.indent_level += 1;
                for (f.body) |s| {
                    try self.printStmt(w, s);
                }
                self.indent_level -= 1;
                self.indent_level -= 1;
            },
            .class_def => |c| {
                try w.print("ClassDef(\"{s}\")\n", .{c.name});
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.print("body({d}):\n", .{c.body.len});
                self.indent_level += 1;
                for (c.body) |s| {
                    try self.printStmt(w, s);
                }
                self.indent_level -= 1;
                self.indent_level -= 1;
            },
            .pass => try w.writeAll("Pass\n"),
            .break_stmt => try w.writeAll("Break\n"),
            .continue_stmt => try w.writeAll("Continue\n"),
            else => try w.print("<{s}>\n", .{@tagName(stmt.*)}),
        }
    }
};

// ============================================================================
// Function Signature Extraction
// ============================================================================

/// Extract function signature from a code object.
/// Returns an Arguments structure suitable for AST function definition.
pub fn extractFunctionSignature(allocator: std.mem.Allocator, code: *const pyc.Code) !*ast.Arguments {
    const args = try allocator.create(ast.Arguments);
    errdefer allocator.destroy(args);

    // Calculate argument positions
    const argcount = code.argcount;
    const posonlyargcount = code.posonlyargcount;
    const kwonlyargcount = code.kwonlyargcount;

    // Position-only args: varnames[0..posonlyargcount]
    var posonly_args: []ast.Arg = &.{};
    if (posonlyargcount > 0 and code.varnames.len >= posonlyargcount) {
        posonly_args = try allocator.alloc(ast.Arg, posonlyargcount);
        for (code.varnames[0..posonlyargcount], 0..) |name, i| {
            posonly_args[i] = .{ .arg = name, .annotation = null, .type_comment = null };
        }
    }

    // Regular args: varnames[posonlyargcount..argcount]
    var regular_args: []ast.Arg = &.{};
    const regular_start = posonlyargcount;
    const regular_end = argcount;
    if (regular_end > regular_start and code.varnames.len >= regular_end) {
        regular_args = try allocator.alloc(ast.Arg, regular_end - regular_start);
        for (code.varnames[regular_start..regular_end], 0..) |name, i| {
            regular_args[i] = .{ .arg = name, .annotation = null, .type_comment = null };
        }
    }

    // Keyword-only args: after argcount
    var kwonly_args: []ast.Arg = &.{};
    const kwonly_start = argcount;
    const kwonly_end = argcount + kwonlyargcount;
    if (kwonlyargcount > 0 and code.varnames.len >= kwonly_end) {
        kwonly_args = try allocator.alloc(ast.Arg, kwonlyargcount);
        for (code.varnames[kwonly_start..kwonly_end], 0..) |name, i| {
            kwonly_args[i] = .{ .arg = name, .annotation = null, .type_comment = null };
        }
    }

    // TODO: Extract *args and **kwargs from code flags and varnames

    args.* = .{
        .posonlyargs = posonly_args,
        .args = regular_args,
        .vararg = null, // TODO: detect from code.flags
        .kwonlyargs = kwonly_args,
        .kw_defaults = &.{},
        .kwarg = null, // TODO: detect from code.flags
        .defaults = &.{}, // TODO: extract from consts
    };

    return args;
}

/// Extract function name from code object.
pub fn extractFunctionName(code: *const pyc.Code) []const u8 {
    if (code.name.len > 0) {
        return code.name;
    }
    return "<unknown>";
}

/// Check if code object is a lambda (has name "<lambda>").
pub fn isLambda(code: *const pyc.Code) bool {
    return std.mem.eql(u8, code.name, "<lambda>");
}

/// Check if code object is a generator (from code flags).
pub fn isGenerator(code: *const pyc.Code) bool {
    // CO_GENERATOR = 0x20
    return (code.flags & 0x20) != 0;
}

/// Check if code object is a coroutine (from code flags).
pub fn isCoroutine(code: *const pyc.Code) bool {
    // CO_COROUTINE = 0x80
    return (code.flags & 0x80) != 0;
}

/// Check if code object is an async generator (from code flags).
pub fn isAsyncGenerator(code: *const pyc.Code) bool {
    // CO_ASYNC_GENERATOR = 0x200
    return (code.flags & 0x200) != 0;
}

/// Extract docstring from code object if first constant is a string.
pub fn extractDocstring(code: *const pyc.Code) ?[]const u8 {
    if (code.consts.len > 0) {
        if (code.consts[0] == .string) {
            return code.consts[0].string;
        }
    }
    return null;
}

test "debug printer expr" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    const left = try ast.makeConstant(allocator, .{ .int = 1 });
    const right = try ast.makeConstant(allocator, .{ .int = 2 });
    const binop = try ast.makeBinOp(allocator, left, .add, right);
    defer {
        @constCast(binop).deinit(allocator);
        allocator.destroy(binop);
    }

    var printer = DebugPrinter{};
    try printer.printExpr(buf.writer(allocator), binop);

    const expected =
        \\BinOp(+)
        \\  Constant(1)
        \\  Constant(2)
        \\
    ;
    try testing.expectEqualStrings(expected, buf.items);
}
