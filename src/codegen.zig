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

/// Pick quote character: prefer single quote unless string contains single quotes
fn pickQuote(s: []const u8) u8 {
    for (s) |c| {
        if (c == '\'') return '"';
    }
    return '\'';
}

/// Python source code writer.
pub const Writer = struct {
    output: std.ArrayList(u8),
    indent_level: u32,
    indent_str: []const u8,
    /// When inside an f-string, this is the quote char used by the f-string.
    /// Strings inside expressions must use the opposite quote.
    fstring_quote: ?u8,

    pub fn init(_: std.mem.Allocator) Writer {
        return .{
            .output = .{},
            .indent_level = 0,
            .indent_str = "    ",
            .fstring_quote = null,
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

    /// Write a body block, inserting 'pass' if empty.
    fn writeBody(self: *Writer, allocator: std.mem.Allocator, body: []const *Stmt) WriteError!void {
        if (body.len == 0) {
            try self.writeIndent(allocator);
            try self.write(allocator, "pass\n");
        } else {
            var prev_def = false;
            for (body) |s| {
                const cur_def = s.* == .function_def or s.* == .class_def;
                if (cur_def and prev_def) {
                    try self.writeByte(allocator, '\n');
                    if (self.indent_level == 0) {
                        try self.writeByte(allocator, '\n');
                    }
                }
                try self.writeStmt(allocator, s);
                prev_def = cur_def;
            }
        }
    }

    /// Write an if statement, with special handling for elif chains.
    fn writeIfStmt(self: *Writer, allocator: std.mem.Allocator, i: anytype, is_elif: bool) WriteError!void {
        // Write the keyword
        if (is_elif) {
            try self.write(allocator, "elif ");
        } else {
            try self.write(allocator, "if ");
        }
        try self.writeExpr(allocator, i.condition);
        try self.write(allocator, ":\n");

        // Write body
        self.indent_level += 1;
        try self.writeBody(allocator, i.body);
        self.indent_level -= 1;

        // Write else/elif
        if (i.else_body.len > 0) {
            try self.writeIndent(allocator);
            // Check if else body is a single if statement (elif)
            if (i.else_body.len == 1 and i.else_body[0].* == .if_stmt) {
                try self.writeIfStmt(allocator, i.else_body[0].if_stmt, true);
            } else {
                try self.write(allocator, "else:\n");
                self.indent_level += 1;
                try self.writeBody(allocator, i.else_body);
                self.indent_level -= 1;
            }
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

    fn writeSubscriptSlice(self: *Writer, allocator: std.mem.Allocator, slice: *const Expr) WriteError!void {
        if (slice.* == .tuple and slice.tuple.ctx == .load) {
            const items = slice.tuple.elts;
            if (items.len == 0) {
                try self.write(allocator, "()");
                return;
            }
            for (items, 0..) |item, i| {
                if (i > 0) try self.write(allocator, ", ");
                try self.writeExpr(allocator, item);
            }
            if (items.len == 1) try self.writeByte(allocator, ',');
            return;
        }
        try self.writeExpr(allocator, slice);
    }

    /// Write a match pattern.
    pub fn writePattern(self: *Writer, allocator: std.mem.Allocator, pat: *const ast.Pattern) WriteError!void {
        switch (pat.*) {
            .match_value => |v| try self.writeExpr(allocator, v),
            .match_singleton => |v| try self.writeConstant(allocator, v),
            .match_sequence => |items| {
                try self.writeByte(allocator, '[');
                for (items, 0..) |item, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.writePattern(allocator, item);
                }
                try self.writeByte(allocator, ']');
            },
            .match_mapping => |m| {
                try self.writeByte(allocator, '{');
                for (m.keys, m.patterns, 0..) |key, pattern, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.writeExpr(allocator, key);
                    try self.write(allocator, ": ");
                    try self.writePattern(allocator, pattern);
                }
                if (m.rest) |rest| {
                    if (m.keys.len > 0) try self.write(allocator, ", ");
                    try self.write(allocator, "**");
                    try self.write(allocator, rest);
                }
                try self.writeByte(allocator, '}');
            },
            .match_class => |c| {
                try self.writeExpr(allocator, c.cls);
                try self.writeByte(allocator, '(');
                var first = true;
                for (c.patterns) |p| {
                    if (!first) try self.write(allocator, ", ");
                    first = false;
                    try self.writePattern(allocator, p);
                }
                for (c.kwd_attrs, c.kwd_patterns) |attr, p| {
                    if (!first) try self.write(allocator, ", ");
                    first = false;
                    try self.write(allocator, attr);
                    try self.write(allocator, "=");
                    try self.writePattern(allocator, p);
                }
                try self.writeByte(allocator, ')');
            },
            .match_star => |s| {
                try self.writeByte(allocator, '*');
                try self.write(allocator, s orelse "_");
            },
            .match_as => |a| {
                if (a.pattern) |p| {
                    try self.writePattern(allocator, p);
                    try self.write(allocator, " as ");
                }
                try self.write(allocator, a.name orelse "_");
            },
            .match_or => |items| {
                for (items, 0..) |item, i| {
                    if (i > 0) try self.write(allocator, " | ");
                    try self.writePattern(allocator, item);
                }
            },
        }
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
                const prec: u8 = if (u.op == .not_) 5 else 14;
                const needs_parens = prec < parent_prec;
                if (needs_parens) try self.writeByte(allocator, '(');
                try self.write(allocator, u.op.symbol());
                try self.writeExprPrec(allocator, u.operand, prec);
                if (needs_parens) try self.writeByte(allocator, ')');
            },
            .compare => |c| {
                const prec: u8 = 5;
                const needs_parens = prec < parent_prec;
                if (needs_parens) try self.writeByte(allocator, '(');
                try self.writeExprPrec(allocator, c.left, prec);
                for (c.ops, c.comparators) |op, cmp| {
                    try self.write(allocator, " ");
                    try self.write(allocator, op.symbol());
                    try self.write(allocator, " ");
                    try self.writeExprPrec(allocator, cmp, prec);
                }
                if (needs_parens) try self.writeByte(allocator, ')');
            },
            .named_expr => |n| {
                const prec: u8 = 1;
                const needs_parens = prec < parent_prec;
                if (needs_parens) try self.writeByte(allocator, '(');
                try self.writeExprPrec(allocator, n.target, prec);
                try self.write(allocator, " := ");
                try self.writeExprPrec(allocator, n.value, prec);
                if (needs_parens) try self.writeByte(allocator, ')');
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
                const prec: u8 = 2;
                const needs_parens = prec < parent_prec;
                if (needs_parens) try self.writeByte(allocator, '(');
                try self.writeExprPrec(allocator, i.body, 0);
                try self.write(allocator, " if ");
                try self.writeExprPrec(allocator, i.condition, 0);
                try self.write(allocator, " else ");
                try self.writeExprPrec(allocator, i.else_body, 0);
                if (needs_parens) try self.writeByte(allocator, ')');
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
                try self.writeSubscriptSlice(allocator, s.slice);
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
                // For store context (unpacking targets):
                // - Empty tuple must use [] syntax since bare () is ambiguous
                // - Single element needs trailing comma: a,
                // - Multiple elements: a, b, c (no parens)
                if (t.ctx == .store and t.elts.len == 0) {
                    try self.write(allocator, "[]");
                } else {
                    const need_parens = t.ctx != .store;
                    if (need_parens) try self.writeByte(allocator, '(');
                    for (t.elts, 0..) |e, i| {
                        if (i > 0) try self.write(allocator, ", ");
                        try self.writeExpr(allocator, e);
                    }
                    if (t.elts.len == 1) try self.writeByte(allocator, ',');
                    if (need_parens) try self.writeByte(allocator, ')');
                }
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
            .list_comp => |c| {
                try self.writeByte(allocator, '[');
                try self.writeExpr(allocator, c.elt);
                try self.writeComprehensionClauses(allocator, c.generators);
                try self.writeByte(allocator, ']');
            },
            .set_comp => |c| {
                try self.writeByte(allocator, '{');
                try self.writeExpr(allocator, c.elt);
                try self.writeComprehensionClauses(allocator, c.generators);
                try self.writeByte(allocator, '}');
            },
            .dict_comp => |c| {
                try self.writeByte(allocator, '{');
                try self.writeExpr(allocator, c.key);
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, c.value);
                try self.writeComprehensionClauses(allocator, c.generators);
                try self.writeByte(allocator, '}');
            },
            .generator_exp => |c| {
                try self.writeByte(allocator, '(');
                try self.writeExpr(allocator, c.elt);
                try self.writeComprehensionClauses(allocator, c.generators);
                try self.writeByte(allocator, ')');
            },
            .starred => |s| {
                try self.writeByte(allocator, '*');
                try self.writeExpr(allocator, s.value);
            },
            .formatted_value => |f| {
                // Standalone formatted_value needs f-string wrapper
                try self.writeFormattedValue(allocator, f, false);
            },
            .joined_str => |j| {
                try self.writeJoinedStr(allocator, j);
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
                // Lambda has lowest precedence (0), needs parens in most contexts
                const needs_parens = parent_prec > 0;
                if (needs_parens) try self.writeByte(allocator, '(');
                try self.write(allocator, "lambda");
                const has_args = l.args.posonlyargs.len > 0 or l.args.args.len > 0 or l.args.kwonlyargs.len > 0 or
                    l.args.vararg != null or l.args.kwarg != null;
                if (has_args) try self.writeByte(allocator, ' ');
                try self.writeArguments(allocator, l.args);
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, l.body);
                if (needs_parens) try self.writeByte(allocator, ')');
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
            .big_int => |v| {
                const out = self.output.writer(allocator);
                try v.format("", .{}, out);
            },
            .float => |v| try self.writeFloatLiteral(allocator, v),
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
                const has_newline = std.mem.indexOfScalar(u8, s, '\n') != null;
                if (has_newline) {
                    try self.write(allocator, "\"\"\"");
                    try self.writeStringContentsMultiline(allocator, s, '"', false);
                    try self.write(allocator, "\"\"\"");
                } else {
                    // Inside f-string expressions, use opposite quote from the f-string
                    const quote = if (self.fstring_quote) |fq|
                        (if (fq == '\'') @as(u8, '"') else '\'')
                    else
                        pickQuote(s);
                    try self.writeByte(allocator, quote);
                    try self.writeStringContents(allocator, s, quote, false);
                    try self.writeByte(allocator, quote);
                }
            },
            .bytes => |b| {
                const has_newline = std.mem.indexOfScalar(u8, b, '\n') != null;
                if (has_newline) {
                    try self.write(allocator, "b\"\"\"");
                    try self.writeStringContentsMultiline(allocator, b, '"', true);
                    try self.write(allocator, "\"\"\"");
                } else {
                    // Inside f-string expressions, use opposite quote from the f-string
                    const quote = if (self.fstring_quote) |fq|
                        (if (fq == '\'') @as(u8, '"') else '\'')
                    else
                        pickQuote(b);
                    try self.writeByte(allocator, 'b');
                    try self.writeByte(allocator, quote);
                    try self.writeStringContents(allocator, b, quote, true);
                    try self.writeByte(allocator, quote);
                }
            },
            .tuple => |items| {
                try self.writeByte(allocator, '(');
                for (items, 0..) |item, i| {
                    if (i > 0) try self.write(allocator, ", ");
                    try self.writeConstant(allocator, item);
                }
                if (items.len == 1) try self.writeByte(allocator, ',');
                try self.writeByte(allocator, ')');
            },
            .code => try self.write(allocator, "<code>"),
        }
    }

    fn writeFloatLiteral(self: *Writer, allocator: std.mem.Allocator, v: f64) !void {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch |err| switch (err) {
            error.NoSpaceLeft => {
                const heap = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(heap);
                return self.writeFloatLiteralSlice(allocator, heap);
            },
        };
        try self.writeFloatLiteralSlice(allocator, s);
    }

    fn writeFloatLiteralSlice(self: *Writer, allocator: std.mem.Allocator, s: []const u8) !void {
        const has_alpha = std.mem.indexOfAny(u8, s, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") != null;
        const has_dot = std.mem.indexOfScalar(u8, s, '.') != null;
        const has_exp = std.mem.indexOfAny(u8, s, "eE") != null;
        if (!has_alpha and !has_dot and !has_exp) {
            try self.writeFmt(allocator, "{s}.0", .{s});
        } else {
            try self.write(allocator, s);
        }
    }

    fn writeStringContents(self: *Writer, allocator: std.mem.Allocator, s: []const u8, quote: u8, is_bytes: bool) !void {
        try self.writeStringContentsEx(allocator, s, quote, false, is_bytes);
    }

    fn writeStringContentsMultiline(
        self: *Writer,
        allocator: std.mem.Allocator,
        s: []const u8,
        quote: u8,
        is_bytes: bool,
    ) !void {
        if (!is_bytes) {
            if (std.unicode.Utf8View.init(s)) |view| {
                var it = std.unicode.Utf8View.iterator(view);
                while (it.nextCodepoint()) |cp| {
                    if (cp <= 0x7F) {
                        const c: u8 = @intCast(cp);
                        switch (c) {
                            '\n' => try self.writeByte(allocator, '\n'),
                            '\r' => try self.write(allocator, "\\r"),
                            '\t' => try self.write(allocator, "\\t"),
                            '\\' => try self.write(allocator, "\\\\"),
                            '"' => if (quote == '"') {
                                try self.write(allocator, "\\\"");
                            } else {
                                try self.writeByte(allocator, '"');
                            },
                            '\'' => if (quote == '\'') {
                                try self.write(allocator, "\\'");
                            } else {
                                try self.writeByte(allocator, '\'');
                            },
                            '{', '}' => try self.writeByte(allocator, c),
                            else => {
                                if (c >= 0x20 and c < 0x7F) {
                                    try self.writeByte(allocator, c);
                                } else {
                                    try self.writeFmt(allocator, "\\x{x:0>2}", .{c});
                                }
                            },
                        }
                        continue;
                    }
                    if (cp <= 0xFF) {
                        try self.writeFmt(allocator, "\\x{x:0>2}", .{cp});
                    } else if (cp <= 0xFFFF) {
                        try self.writeFmt(allocator, "\\u{x:0>4}", .{cp});
                    } else {
                        try self.writeFmt(allocator, "\\U{x:0>8}", .{cp});
                    }
                }
                return;
            } else |_| {}
        }

        // Byte fallback (bytes literals or invalid UTF-8)
        for (s) |c| {
            switch (c) {
                '\n' => try self.writeByte(allocator, '\n'),
                '\r' => try self.write(allocator, "\\r"),
                '\t' => try self.write(allocator, "\\t"),
                '\\' => try self.write(allocator, "\\\\"),
                '"' => if (quote == '"') {
                    try self.write(allocator, "\\\"");
                } else {
                    try self.writeByte(allocator, '"');
                },
                '\'' => if (quote == '\'') {
                    try self.write(allocator, "\\'");
                } else {
                    try self.writeByte(allocator, '\'');
                },
                '{', '}' => try self.writeByte(allocator, c),
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

    fn writeStringContentsEx(
        self: *Writer,
        allocator: std.mem.Allocator,
        s: []const u8,
        quote: u8,
        in_fstring: bool,
        is_bytes: bool,
    ) !void {
        if (!is_bytes) {
            if (std.unicode.Utf8View.init(s)) |view| {
                var it = std.unicode.Utf8View.iterator(view);
                while (it.nextCodepoint()) |cp| {
                    if (cp <= 0x7F) {
                        const c: u8 = @intCast(cp);
                        switch (c) {
                            '\n' => try self.write(allocator, "\\n"),
                            '\r' => try self.write(allocator, "\\r"),
                            '\t' => try self.write(allocator, "\\t"),
                            '\\' => try self.write(allocator, "\\\\"),
                            '\'' => if (quote == '\'') {
                                try self.write(allocator, "\\'");
                            } else {
                                try self.writeByte(allocator, '\'');
                            },
                            '"' => if (quote == '"') {
                                try self.write(allocator, "\\\"");
                            } else {
                                try self.writeByte(allocator, '"');
                            },
                            '{' => if (in_fstring) {
                                try self.write(allocator, "{{");
                            } else {
                                try self.writeByte(allocator, '{');
                            },
                            '}' => if (in_fstring) {
                                try self.write(allocator, "}}");
                            } else {
                                try self.writeByte(allocator, '}');
                            },
                            else => {
                                if (c >= 0x20 and c < 0x7F) {
                                    try self.writeByte(allocator, c);
                                } else {
                                    try self.writeFmt(allocator, "\\x{x:0>2}", .{c});
                                }
                            },
                        }
                        continue;
                    }
                    if (cp <= 0xFF) {
                        try self.writeFmt(allocator, "\\x{x:0>2}", .{cp});
                    } else if (cp <= 0xFFFF) {
                        try self.writeFmt(allocator, "\\u{x:0>4}", .{cp});
                    } else {
                        try self.writeFmt(allocator, "\\U{x:0>8}", .{cp});
                    }
                }
                return;
            } else |_| {}
        }

        // Byte fallback (bytes literals or invalid UTF-8)
        for (s) |c| {
            switch (c) {
                '\n' => try self.write(allocator, "\\n"),
                '\r' => try self.write(allocator, "\\r"),
                '\t' => try self.write(allocator, "\\t"),
                '\\' => try self.write(allocator, "\\\\"),
                '\'' => if (quote == '\'') {
                    try self.write(allocator, "\\'");
                } else {
                    try self.writeByte(allocator, '\'');
                },
                '"' => if (quote == '"') {
                    try self.write(allocator, "\\\"");
                } else {
                    try self.writeByte(allocator, '"');
                },
                '{' => if (in_fstring) {
                    try self.write(allocator, "{{");
                } else {
                    try self.writeByte(allocator, '{');
                },
                '}' => if (in_fstring) {
                    try self.write(allocator, "}}");
                } else {
                    try self.writeByte(allocator, '}');
                },
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

    /// Check if an expression contains string constants with a specific quote char.
    fn exprHasQuote(expr: *const Expr, quote: u8) bool {
        switch (expr.*) {
            .constant => |c| {
                if (c == .string) {
                    for (c.string) |ch| {
                        if (ch == quote) return true;
                    }
                }
                return false;
            },
            .formatted_value => |f| {
                if (exprHasQuote(f.value, quote)) return true;
                if (f.format_spec) |spec| {
                    if (exprHasQuote(spec, quote)) return true;
                }
                return false;
            },
            .joined_str => |j| {
                for (j.values) |v| {
                    if (exprHasQuote(v, quote)) return true;
                }
                return false;
            },
            .bin_op => |b| return exprHasQuote(b.left, quote) or exprHasQuote(b.right, quote),
            .unary_op => |u| return exprHasQuote(u.operand, quote),
            .call => |c| {
                if (exprHasQuote(c.func, quote)) return true;
                for (c.args) |a| {
                    if (exprHasQuote(a, quote)) return true;
                }
                for (c.keywords) |kw| {
                    if (exprHasQuote(kw.value, quote)) return true;
                }
                return false;
            },
            .attribute => |a| return exprHasQuote(a.value, quote),
            .subscript => |s| return exprHasQuote(s.value, quote) or exprHasQuote(s.slice, quote),
            .list => |l| {
                for (l.elts) |e| {
                    if (exprHasQuote(e, quote)) return true;
                }
                return false;
            },
            .tuple => |t| {
                for (t.elts) |e| {
                    if (exprHasQuote(e, quote)) return true;
                }
                return false;
            },
            .dict => |d| {
                for (d.keys) |k| {
                    if (k != null and exprHasQuote(k.?, quote)) return true;
                }
                for (d.values) |v| {
                    if (exprHasQuote(v, quote)) return true;
                }
                return false;
            },
            .if_exp => |i| {
                return exprHasQuote(i.condition, quote) or
                    exprHasQuote(i.body, quote) or
                    exprHasQuote(i.else_body, quote);
            },
            .compare => |c| {
                if (exprHasQuote(c.left, quote)) return true;
                for (c.comparators) |cmp| {
                    if (exprHasQuote(cmp, quote)) return true;
                }
                return false;
            },
            .bool_op => |b| {
                for (b.values) |v| {
                    if (exprHasQuote(v, quote)) return true;
                }
                return false;
            },
            .lambda => |l| return exprHasQuote(l.body, quote),
            else => return false,
        }
    }

    /// Pick quote char for f-string: prefer single unless expressions contain single quotes.
    fn pickFstringQuote(values: []const *Expr) u8 {
        // Check all formatted values for quote usage
        for (values) |v| {
            if (v.* == .formatted_value) {
                if (exprHasQuote(v.formatted_value.value, '\'')) return '"';
            }
        }
        return '\'';
    }

    /// Write a joined_str (f-string).
    fn writeJoinedStr(self: *Writer, allocator: std.mem.Allocator, j: anytype) WriteError!void {
        const quote: u8 = if (self.fstring_quote) |fq|
            @as(u8, if (fq == '\'') '"' else '\'')
        else
            pickFstringQuote(j.values);
        const saved_fstring_quote = self.fstring_quote;
        self.fstring_quote = quote;
        defer self.fstring_quote = saved_fstring_quote;

        try self.writeByte(allocator, 'f');
        try self.writeByte(allocator, quote);
        var i: usize = 0;
        while (i < j.values.len) : (i += 1) {
            const v = j.values[i];
            // Check for debug syntax: "name=" followed by formatted_value with repr and matching name
            if (i + 1 < j.values.len and v.* == .constant and v.constant == .string) {
                const s = v.constant.string;
                if (s.len > 0 and s[s.len - 1] == '=') {
                    const next = j.values[i + 1];
                    if (next.* == .formatted_value) {
                        const fv = next.formatted_value;
                        if (fv.conversion == 'r' and fv.format_spec == null and fv.value.* == .name) {
                            const prefix = s[0 .. s.len - 1];
                            if (std.mem.eql(u8, prefix, fv.value.name.id)) {
                                // Debug syntax: {name=}
                                try self.writeByte(allocator, '{');
                                try self.write(allocator, fv.value.name.id);
                                try self.writeByte(allocator, '=');
                                try self.writeByte(allocator, '}');
                                i += 1; // Skip next value
                                continue;
                            }
                        }
                    }
                }
            }
            switch (v.*) {
                .constant => |c| {
                    if (c == .string) {
                        try self.writeStringContentsEx(allocator, c.string, quote, true, false);
                    }
                },
                .formatted_value => |f| {
                    try self.writeFormattedValueInner(allocator, f);
                },
                else => try self.writeExpr(allocator, v),
            }
        }
        try self.writeByte(allocator, quote);
    }

    /// Write a formatted value inside an f-string (no prefix needed).
    fn writeFormattedValueInner(self: *Writer, allocator: std.mem.Allocator, f: anytype) WriteError!void {
        try self.writeByte(allocator, '{');
        try self.writeExpr(allocator, f.value);
        if (f.conversion) |c| {
            try self.writeByte(allocator, '!');
            try self.writeByte(allocator, c);
        }
        if (f.format_spec) |spec| {
            try self.writeByte(allocator, ':');
            try self.writeFormatSpec(allocator, spec);
        }
        try self.writeByte(allocator, '}');
    }

    /// Write a standalone formatted value (wraps with f'...').
    fn writeFormattedValue(self: *Writer, allocator: std.mem.Allocator, f: anytype, in_fstring: bool) WriteError!void {
        if (!in_fstring) {
            // Standalone formatted value - pick quote based on content
            const quote: u8 = if (exprHasQuote(f.value, '\'')) '"' else '\'';
            const saved_fstring_quote = self.fstring_quote;
            self.fstring_quote = quote;
            defer self.fstring_quote = saved_fstring_quote;

            try self.writeByte(allocator, 'f');
            try self.writeByte(allocator, quote);
            try self.writeFormattedValueInner(allocator, f);
            try self.writeByte(allocator, quote);
        } else {
            try self.writeFormattedValueInner(allocator, f);
        }
    }

    /// Write format spec (the part after : in f-string).
    fn writeFormatSpec(self: *Writer, allocator: std.mem.Allocator, spec: *const Expr) WriteError!void {
        if (spec.* == .constant and spec.constant == .string) {
            try self.write(allocator, spec.constant.string);
        } else if (spec.* == .joined_str) {
            // Nested f-string format spec
            for (spec.joined_str.values) |v| {
                if (v.* == .constant and v.constant == .string) {
                    try self.write(allocator, v.constant.string);
                } else if (v.* == .formatted_value) {
                    try self.writeFormattedValue(allocator, v.formatted_value, true);
                } else {
                    try self.writeExpr(allocator, v);
                }
            }
        } else {
            try self.writeExpr(allocator, spec);
        }
    }

    fn writeArguments(self: *Writer, allocator: std.mem.Allocator, args: *const ast.Arguments) !void {
        var first = true;

        const n_defaults = args.defaults.len;
        const n_total_pos = args.posonlyargs.len + args.args.len;
        const defaults_start = if (n_defaults > 0) n_total_pos - n_defaults else n_total_pos;
        var pos_idx: usize = 0;

        // Write positional-only args
        for (args.posonlyargs) |arg| {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, arg.arg);
            if (arg.annotation) |ann| {
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, ann);
            }
            if (n_defaults > 0 and pos_idx >= defaults_start) {
                const default_idx = pos_idx - defaults_start;
                try self.write(allocator, " = ");
                try self.writeExpr(allocator, args.defaults[default_idx]);
            }
            pos_idx += 1;
        }

        if (args.posonlyargs.len > 0) {
            try self.write(allocator, ", /");
        }

        // Write regular args with defaults
        for (args.args) |arg| {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, arg.arg);
            if (arg.annotation) |ann| {
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, ann);
            }
            if (n_defaults > 0 and pos_idx >= defaults_start) {
                const default_idx = pos_idx - defaults_start;
                try self.write(allocator, " = ");
                try self.writeExpr(allocator, args.defaults[default_idx]);
            }
            pos_idx += 1;
        }

        // Write *args
        if (args.vararg) |va| {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, "*");
            try self.write(allocator, va.arg);
            if (va.annotation) |ann| {
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, ann);
            }
        }

        if (args.kwonlyargs.len > 0 and args.vararg == null) {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, "*");
        }

        // Write keyword-only args with defaults
        for (args.kwonlyargs, 0..) |arg, i| {
            if (!first) try self.write(allocator, ", ");
            first = false;
            try self.write(allocator, arg.arg);
            if (arg.annotation) |ann| {
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, ann);
            }
            if (i < args.kw_defaults.len) {
                if (args.kw_defaults[i]) |default| {
                    try self.write(allocator, " = ");
                    try self.writeExpr(allocator, default);
                }
            }
        }

        // Write **kwargs
        if (args.kwarg) |kw| {
            if (!first) try self.write(allocator, ", ");
            try self.write(allocator, "**");
            try self.write(allocator, kw.arg);
            if (kw.annotation) |ann| {
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, ann);
            }
        }
    }

    fn writeComprehensionClauses(self: *Writer, allocator: std.mem.Allocator, generators: []const ast.Comprehension) !void {
        for (generators) |gen| {
            try self.write(allocator, " for ");
            try self.writeExpr(allocator, gen.target);
            try self.write(allocator, " in ");
            try self.writeExpr(allocator, gen.iter);
            for (gen.ifs) |cond| {
                try self.write(allocator, " if ");
                try self.writeExpr(allocator, cond);
            }
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
            .print_stmt => |p| {
                try self.write(allocator, "print");
                if (p.dest) |dest| {
                    try self.write(allocator, " >>");
                    try self.writeExpr(allocator, dest);
                    if (p.values.len > 0) try self.writeByte(allocator, ',');
                }
                for (p.values, 0..) |val, i| {
                    try self.writeByte(allocator, ' ');
                    try self.writeExpr(allocator, val);
                    if (i + 1 < p.values.len) try self.writeByte(allocator, ',');
                }
                if (!p.nl and p.values.len > 0) try self.writeByte(allocator, ',');
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
                // For chain assignments with multiple targets, tuple targets need parens
                const multi_target = a.targets.len > 1;
                for (a.targets, 0..) |t, i| {
                    if (i > 0) try self.write(allocator, " = ");
                    // Wrap tuple targets in parens for chain assignments
                    const needs_parens = multi_target and t.* == .tuple;
                    if (needs_parens) try self.writeByte(allocator, '(');
                    try self.writeExpr(allocator, t);
                    if (needs_parens) try self.writeByte(allocator, ')');
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
            .ann_assign => |a| {
                try self.writeExpr(allocator, a.target);
                try self.write(allocator, ": ");
                try self.writeExpr(allocator, a.annotation);
                if (a.value) |v| {
                    try self.write(allocator, " = ");
                    try self.writeExpr(allocator, v);
                }
                try self.writeByte(allocator, '\n');
            },
            .if_stmt => |i| {
                try self.writeIfStmt(allocator, i, false);
            },
            .while_stmt => |w| {
                try self.write(allocator, "while ");
                try self.writeExpr(allocator, w.condition);
                try self.write(allocator, ":\n");
                self.indent_level += 1;
                try self.writeBody(allocator, w.body);
                self.indent_level -= 1;
                if (w.else_body.len > 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "else:\n");
                    self.indent_level += 1;
                    try self.writeBody(allocator, w.else_body);
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
                try self.writeBody(allocator, f.body);
                self.indent_level -= 1;
                if (f.else_body.len > 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "else:\n");
                    self.indent_level += 1;
                    try self.writeBody(allocator, f.else_body);
                    self.indent_level -= 1;
                }
            },
            .with_stmt => |w| {
                if (w.is_async) try self.write(allocator, "async ");
                try self.write(allocator, "with ");
                for (w.items, 0..) |item, idx| {
                    if (idx > 0) try self.write(allocator, ", ");
                    try self.writeExpr(allocator, item.context_expr);
                    if (item.optional_vars) |vars| {
                        try self.write(allocator, " as ");
                        try self.writeExpr(allocator, vars);
                    }
                }
                try self.write(allocator, ":\n");
                self.indent_level += 1;
                try self.writeBody(allocator, w.body);
                self.indent_level -= 1;
            },
            .match_stmt => |m| {
                try self.write(allocator, "match ");
                try self.writeExpr(allocator, m.subject);
                try self.write(allocator, ":\n");
                self.indent_level += 1;
                for (m.cases) |case| {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "case ");
                    try self.writePattern(allocator, case.pattern);
                    if (case.guard) |guard| {
                        try self.write(allocator, " if ");
                        try self.writeExpr(allocator, guard);
                    }
                    try self.write(allocator, ":\n");
                    self.indent_level += 1;
                    if (case.body.len == 0) {
                        try self.writeIndent(allocator);
                        try self.write(allocator, "pass\n");
                    } else {
                        for (case.body) |s| {
                            try self.writeStmt(allocator, s);
                        }
                    }
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
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
                    for (f.body, 0..) |s, i| {
                        // First statement might be docstring
                        if (i == 0 and s.* == .expr_stmt) {
                            const expr = s.expr_stmt.value;
                            if (expr.* == .constant and expr.constant == .string) {
                                try self.writeIndent(allocator);
                                try self.write(allocator, "\"\"\"");
                                try self.writeStringContentsMultiline(allocator, expr.constant.string, '"', false);
                                try self.write(allocator, "\"\"\"\n");
                                continue;
                            }
                        }
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
                    for (c.body, 0..) |s, i| {
                        // First statement might be docstring
                        if (i == 0 and s.* == .expr_stmt) {
                            const expr = s.expr_stmt.value;
                            if (expr.* == .constant and expr.constant == .string) {
                                try self.writeIndent(allocator);
                                try self.write(allocator, "\"\"\"");
                                try self.writeStringContentsMultiline(allocator, expr.constant.string, '"', false);
                                try self.write(allocator, "\"\"\"\n");
                                continue;
                            }
                        }
                        // Skip __doc__ assignment (it's the docstring)
                        if (s.* == .assign) {
                            const assign = s.assign;
                            if (assign.targets.len == 1) {
                                const target = assign.targets[0];
                                if (target.* == .name and std.mem.eql(u8, target.name.id, "__doc__")) {
                                    continue;
                                }
                            }
                        }
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
            .try_stmt => |t| {
                try self.write(allocator, "try:\n");
                self.indent_level += 1;
                try self.writeBody(allocator, t.body);
                self.indent_level -= 1;

                for (t.handlers) |h| {
                    if (h.type == null) continue;
                    try self.writeIndent(allocator);
                    try self.write(allocator, "except");
                    if (h.type) |exc| {
                        try self.writeByte(allocator, ' ');
                        try self.writeExpr(allocator, exc);
                        if (h.name) |name| {
                            try self.write(allocator, " as ");
                            try self.write(allocator, name);
                        }
                    }
                    try self.write(allocator, ":\n");
                    self.indent_level += 1;
                    try self.writeBody(allocator, h.body);
                    self.indent_level -= 1;
                }
                for (t.handlers) |h| {
                    if (h.type != null) continue;
                    try self.writeIndent(allocator);
                    try self.write(allocator, "except");
                    try self.write(allocator, ":\n");
                    self.indent_level += 1;
                    try self.writeBody(allocator, h.body);
                    self.indent_level -= 1;
                }

                if (t.else_body.len > 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "else:\n");
                    self.indent_level += 1;
                    try self.writeBody(allocator, t.else_body);
                    self.indent_level -= 1;
                }

                if (t.finalbody.len > 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "finally:\n");
                    self.indent_level += 1;
                    try self.writeBody(allocator, t.finalbody);
                    self.indent_level -= 1;
                } else if (t.handlers.len == 0 and t.else_body.len == 0) {
                    try self.writeIndent(allocator);
                    try self.write(allocator, "finally:\n");
                    self.indent_level += 1;
                    try self.writeIndent(allocator);
                    try self.write(allocator, "pass\n");
                    self.indent_level -= 1;
                }
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

test "codegen big int constant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const digits = try arena_alloc.alloc(u16, 5);
    digits[0] = 0;
    digits[1] = 0;
    digits[2] = 0;
    digits[3] = 0;
    digits[4] = 1024;
    const big = pyc.BigInt{ .digits = digits, .negative = false };

    const expr = try ast.makeConstant(arena_alloc, .{ .big_int = big });

    var writer = Writer.init(allocator);
    defer writer.deinit(allocator);

    try writer.writeExpr(allocator, expr);
    const output = try writer.getOutput(allocator);
    defer allocator.free(output);

    try testing.expectEqualStrings("1180591620717411303424", output);
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

    try testing.expectEqualStrings("\"\"\"hello\nworld\"\"\"", output);
}

test "codegen with statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const context_expr = try ast.makeName(arena_alloc, "cm", .load);
    const optional_vars = try ast.makeName(arena_alloc, "v", .store);
    const items = try arena_alloc.alloc(ast.WithItem, 1);
    items[0] = .{
        .context_expr = context_expr,
        .optional_vars = optional_vars,
    };

    const body_stmt = try arena_alloc.create(Stmt);
    body_stmt.* = .pass;
    const body = try arena_alloc.alloc(*Stmt, 1);
    body[0] = body_stmt;

    const with_stmt = try arena_alloc.create(Stmt);
    with_stmt.* = .{
        .with_stmt = .{
            .items = items,
            .body = body,
            .type_comment = null,
            .is_async = false,
        },
    };

    var writer = Writer.init(allocator);
    defer writer.deinit(allocator);

    try writer.writeStmt(allocator, with_stmt);
    const output = try writer.getOutput(allocator);
    defer allocator.free(output);

    try testing.expectEqualStrings(
        "with cm as v:\n    pass\n",
        output,
    );
}

test "codegen try statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const try_body_stmt = try arena_alloc.create(Stmt);
    try_body_stmt.* = .pass;
    const try_body = try arena_alloc.alloc(*Stmt, 1);
    try_body[0] = try_body_stmt;

    const handler_body_stmt = try arena_alloc.create(Stmt);
    handler_body_stmt.* = .pass;
    const handler_body = try arena_alloc.alloc(*Stmt, 1);
    handler_body[0] = handler_body_stmt;

    const exc_type = try ast.makeName(arena_alloc, "Exception", .load);
    const handlers = try arena_alloc.alloc(ast.ExceptHandler, 1);
    handlers[0] = .{
        .type = exc_type,
        .name = "e",
        .body = handler_body,
    };

    const else_stmt = try arena_alloc.create(Stmt);
    else_stmt.* = .pass;
    const else_body = try arena_alloc.alloc(*Stmt, 1);
    else_body[0] = else_stmt;

    const finally_stmt = try arena_alloc.create(Stmt);
    finally_stmt.* = .pass;
    const final_body = try arena_alloc.alloc(*Stmt, 1);
    final_body[0] = finally_stmt;

    const try_stmt = try arena_alloc.create(Stmt);
    try_stmt.* = .{
        .try_stmt = .{
            .body = try_body,
            .handlers = handlers,
            .else_body = else_body,
            .finalbody = final_body,
        },
    };

    var writer = Writer.init(allocator);
    defer writer.deinit(allocator);

    try writer.writeStmt(allocator, try_stmt);
    const output = try writer.getOutput(allocator);
    defer allocator.free(output);

    try testing.expectEqualStrings(
        "try:\n    pass\nexcept Exception as e:\n    pass\nelse:\n    pass\nfinally:\n    pass\n",
        output,
    );
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
            .list_comp => |c| {
                try w.writeAll("ListComp\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("elt:\n");
                self.indent_level += 1;
                try self.printExpr(w, c.elt);
                self.indent_level -= 1;
                for (c.generators, 0..) |gen, idx| {
                    try self.writeIndent(w);
                    try w.print("gen[{d}]\n", .{idx});
                    self.indent_level += 1;
                    try self.writeIndent(w);
                    try w.writeAll("target:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, gen.target);
                    self.indent_level -= 1;
                    try self.writeIndent(w);
                    try w.writeAll("iter:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, gen.iter);
                    self.indent_level -= 1;
                    if (gen.ifs.len > 0) {
                        try self.writeIndent(w);
                        try w.writeAll("ifs:\n");
                        self.indent_level += 1;
                        for (gen.ifs) |cond| {
                            try self.printExpr(w, cond);
                        }
                        self.indent_level -= 1;
                    }
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
            },
            .set_comp => |c| {
                try w.writeAll("SetComp\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("elt:\n");
                self.indent_level += 1;
                try self.printExpr(w, c.elt);
                self.indent_level -= 1;
                for (c.generators, 0..) |gen, idx| {
                    try self.writeIndent(w);
                    try w.print("gen[{d}]\n", .{idx});
                    self.indent_level += 1;
                    try self.writeIndent(w);
                    try w.writeAll("target:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, gen.target);
                    self.indent_level -= 1;
                    try self.writeIndent(w);
                    try w.writeAll("iter:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, gen.iter);
                    self.indent_level -= 1;
                    if (gen.ifs.len > 0) {
                        try self.writeIndent(w);
                        try w.writeAll("ifs:\n");
                        self.indent_level += 1;
                        for (gen.ifs) |cond| {
                            try self.printExpr(w, cond);
                        }
                        self.indent_level -= 1;
                    }
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
            },
            .dict_comp => |c| {
                try w.writeAll("DictComp\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("key:\n");
                self.indent_level += 1;
                try self.printExpr(w, c.key);
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.writeAll("value:\n");
                self.indent_level += 1;
                try self.printExpr(w, c.value);
                self.indent_level -= 1;
                for (c.generators, 0..) |gen, idx| {
                    try self.writeIndent(w);
                    try w.print("gen[{d}]\n", .{idx});
                    self.indent_level += 1;
                    try self.writeIndent(w);
                    try w.writeAll("target:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, gen.target);
                    self.indent_level -= 1;
                    try self.writeIndent(w);
                    try w.writeAll("iter:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, gen.iter);
                    self.indent_level -= 1;
                    if (gen.ifs.len > 0) {
                        try self.writeIndent(w);
                        try w.writeAll("ifs:\n");
                        self.indent_level += 1;
                        for (gen.ifs) |cond| {
                            try self.printExpr(w, cond);
                        }
                        self.indent_level -= 1;
                    }
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
            },
            .generator_exp => |c| {
                try w.writeAll("GeneratorExp\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.writeAll("elt:\n");
                self.indent_level += 1;
                try self.printExpr(w, c.elt);
                self.indent_level -= 1;
                for (c.generators, 0..) |gen, idx| {
                    try self.writeIndent(w);
                    try w.print("gen[{d}]\n", .{idx});
                    self.indent_level += 1;
                    try self.writeIndent(w);
                    try w.writeAll("target:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, gen.target);
                    self.indent_level -= 1;
                    try self.writeIndent(w);
                    try w.writeAll("iter:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, gen.iter);
                    self.indent_level -= 1;
                    if (gen.ifs.len > 0) {
                        try self.writeIndent(w);
                        try w.writeAll("ifs:\n");
                        self.indent_level += 1;
                        for (gen.ifs) |cond| {
                            try self.printExpr(w, cond);
                        }
                        self.indent_level -= 1;
                    }
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
        switch (c) {
            .none => try w.writeAll("None"),
            .true_ => try w.writeAll("True"),
            .false_ => try w.writeAll("False"),
            .ellipsis => try w.writeAll("..."),
            .int => |v| try w.print("{d}", .{v}),
            .big_int => |v| try v.format("", .{}, w),
            .float => |v| try w.print("{d}", .{v}),
            .complex => |v| try w.print("{d}+{d}j", .{ v.real, v.imag }),
            .string => |s| try w.print("\"{s}\"", .{s}),
            .bytes => |b| try w.print("b\"{s}\"", .{b}),
            .tuple => |items| {
                try w.writeByte('(');
                for (items, 0..) |item, i| {
                    if (i > 0) try w.writeAll(", ");
                    try self.printConstant(w, item);
                }
                if (items.len == 1) try w.writeByte(',');
                try w.writeByte(')');
            },
            .code => try w.writeAll("<code>"),
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
            .with_stmt => |w_stmt| {
                if (w_stmt.is_async) {
                    try w.writeAll("AsyncWith\n");
                } else {
                    try w.writeAll("With\n");
                }
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.print("items({d}):\n", .{w_stmt.items.len});
                self.indent_level += 1;
                for (w_stmt.items) |item| {
                    try self.writeIndent(w);
                    try w.writeAll("item:\n");
                    self.indent_level += 1;
                    try self.writeIndent(w);
                    try w.writeAll("context:\n");
                    self.indent_level += 1;
                    try self.printExpr(w, item.context_expr);
                    self.indent_level -= 1;
                    if (item.optional_vars) |vars| {
                        try self.writeIndent(w);
                        try w.writeAll("as:\n");
                        self.indent_level += 1;
                        try self.printExpr(w, vars);
                        self.indent_level -= 1;
                    }
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.print("body({d}):\n", .{w_stmt.body.len});
                self.indent_level += 1;
                for (w_stmt.body) |s| {
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
            .try_stmt => |t| {
                try w.writeAll("Try\n");
                self.indent_level += 1;
                try self.writeIndent(w);
                try w.print("body({d}):\n", .{t.body.len});
                self.indent_level += 1;
                for (t.body) |s| {
                    try self.printStmt(w, s);
                }
                self.indent_level -= 1;
                try self.writeIndent(w);
                try w.print("handlers({d}):\n", .{t.handlers.len});
                self.indent_level += 1;
                for (t.handlers) |h| {
                    try self.writeIndent(w);
                    try w.writeAll("handler:\n");
                    self.indent_level += 1;
                    if (h.type) |exc| {
                        try self.writeIndent(w);
                        try w.writeAll("type:\n");
                        self.indent_level += 1;
                        try self.printExpr(w, exc);
                        self.indent_level -= 1;
                    }
                    if (h.name) |name| {
                        try self.writeIndent(w);
                        try w.print("name: {s}\n", .{name});
                    }
                    try self.writeIndent(w);
                    try w.print("body({d}):\n", .{h.body.len});
                    self.indent_level += 1;
                    for (h.body) |s| {
                        try self.printStmt(w, s);
                    }
                    self.indent_level -= 1;
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
                if (t.else_body.len > 0) {
                    try self.writeIndent(w);
                    try w.print("else({d}):\n", .{t.else_body.len});
                    self.indent_level += 1;
                    for (t.else_body) |s| {
                        try self.printStmt(w, s);
                    }
                    self.indent_level -= 1;
                }
                if (t.finalbody.len > 0) {
                    try self.writeIndent(w);
                    try w.print("finally({d}):\n", .{t.finalbody.len});
                    self.indent_level += 1;
                    for (t.finalbody) |s| {
                        try self.printStmt(w, s);
                    }
                    self.indent_level -= 1;
                }
                self.indent_level -= 1;
            },
            .pass => try w.writeAll("Pass\n"),
            .break_stmt => try w.writeAll("Break\n"),
            .continue_stmt => try w.writeAll("Continue\n"),
            else => try w.print("<{s}>\n", .{@tagName(stmt.*)}),
        }
    }
};

/// Extract function name from code object.
pub fn extractFunctionName(code: *const pyc.Code) []const u8 {
    if (code.name.len > 0) {
        return code.name;
    }
    return "__unknown__";
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

/// Extract docstring from code object.
/// A docstring is the first statement of a function that is a string literal.
/// Detection strategy:
/// - Python 3.11-3.13: RESUME, LOAD_CONST 0, POP_TOP pattern
/// - Python 3.14+: const[0] is a string but never loaded (optimized away)
pub fn extractDocstring(code: *const pyc.Code) ?[]const u8 {
    // Need at least a string constant
    if (code.consts.len == 0) return null;
    if (code.consts[0] != .string) return null;

    if (code.code.len < 4) return null;

    // Check if bytecode ever loads const[0]
    // LOAD_CONST opcodes: 100 (pre-3.11), 83 (3.12-3.13), 82 (3.14+)
    var loads_const_0 = false;
    var offset: usize = 0;
    while (offset + 1 < code.code.len) {
        const opcode = code.code[offset];
        const arg = code.code[offset + 1];

        // Check various LOAD_CONST opcodes
        if ((opcode == 100 or opcode == 83 or opcode == 82) and arg == 0) {
            loads_const_0 = true;
            break;
        }

        offset += 2; // Word-aligned bytecode (Python 3.6+)
    }

    if (!loads_const_0) {
        // Python 3.14+ style: docstring stored but not loaded
        return code.consts[0].string;
    }

    // Python 3.11-3.13 style: check for LOAD_CONST 0 followed by POP_TOP
    // offset 0: RESUME (128, 149-151)
    // offset 2: LOAD_CONST 0
    // offset 4: POP_TOP (31)
    if (code.code.len >= 6) {
        const inst2_opcode = code.code[2];
        const inst2_arg = code.code[3];
        const inst4_opcode = code.code[4];

        // LOAD_CONST (100, 83, 82) with arg 0, followed by POP_TOP (31)
        if ((inst2_opcode == 100 or inst2_opcode == 83 or inst2_opcode == 82) and
            inst2_arg == 0 and inst4_opcode == 31)
        {
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
