//! Main decompilation logic.
//!
//! Combines CFG analysis, control flow detection, and stack simulation
//! to reconstruct Python source code from bytecode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const cfg_mod = @import("cfg.zig");
const ctrl = @import("ctrl.zig");
const decoder = @import("decoder.zig");
const stack_mod = @import("stack.zig");
const pyc = @import("pyc.zig");
const codegen = @import("codegen.zig");

pub const CFG = cfg_mod.CFG;
pub const BasicBlock = cfg_mod.BasicBlock;
pub const Analyzer = ctrl.Analyzer;
pub const SimContext = stack_mod.SimContext;
pub const Version = decoder.Version;
pub const Expr = ast.Expr;
pub const Stmt = ast.Stmt;

/// Decompiler state for a single code object.
pub const Decompiler = struct {
    allocator: Allocator,
    code: *const pyc.Code,
    version: Version,
    cfg: *CFG,
    analyzer: Analyzer,

    /// Accumulated statements.
    statements: std.ArrayList(*Stmt),

    pub fn init(allocator: Allocator, code: *const pyc.Code, version: Version) !Decompiler {
        // Allocate CFG on heap so pointer stays valid
        const cfg = try allocator.create(CFG);
        errdefer allocator.destroy(cfg);

        cfg.* = try cfg_mod.buildCFG(allocator, code.code, version);
        errdefer cfg.deinit();

        var analyzer = try Analyzer.init(allocator, cfg);
        errdefer analyzer.deinit();

        return .{
            .allocator = allocator,
            .code = code,
            .version = version,
            .cfg = cfg,
            .analyzer = analyzer,
            .statements = .{},
        };
    }

    pub fn deinit(self: *Decompiler) void {
        self.analyzer.deinit();
        self.cfg.deinit();
        self.allocator.destroy(self.cfg);
        for (self.statements.items) |stmt| {
            self.allocator.destroy(stmt);
        }
        self.statements.deinit(self.allocator);
    }

    /// Find the last block that's part of an if-elif-else chain.
    fn findIfChainEnd(self: *Decompiler, pattern: ctrl.IfPattern) u32 {
        var max_block = pattern.then_block;

        if (pattern.else_block) |else_id| {
            max_block = @max(max_block, else_id);

            // If this is an elif, recursively find its end
            if (pattern.is_elif) {
                const else_pattern = self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    max_block = @max(max_block, self.findIfChainEnd(else_pattern.if_stmt));
                }
            }
        }

        if (pattern.merge_block) |merge| {
            return merge;
        }

        // No merge point - return past the last block in the chain
        return max_block + 1;
    }

    /// Decompile the code object into a list of statements.
    pub fn decompile(self: *Decompiler) ![]const *Stmt {
        if (self.cfg.blocks.len == 0) {
            return self.statements.items;
        }

        // Process blocks in order, using control flow patterns
        var block_idx: u32 = 0;
        while (block_idx < self.cfg.blocks.len) {
            const pattern = self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    const stmt = try self.decompileIf(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    // Skip all processed blocks
                    block_idx = self.findIfChainEnd(p);
                },
                .while_loop => |p| {
                    const stmt = try self.decompileWhile(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .for_loop => |p| {
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                else => {
                    // Process block as sequential statements
                    try self.decompileBlock(block_idx);
                    block_idx += 1;
                },
            }
        }

        return self.statements.items;
    }

    /// Decompile a single basic block into statements.
    fn decompileBlock(self: *Decompiler, block_id: u32) !void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            // Check for statement-producing instructions
            switch (inst.opcode) {
                .STORE_NAME, .STORE_FAST, .STORE_GLOBAL => {
                    // This is an assignment
                    if (sim.stack.popExpr()) |value| {
                        const name = switch (inst.opcode) {
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                            .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                            else => "<unknown>",
                        };

                        const target = try ast.makeName(self.allocator, name, .store);
                        const stmt = try self.makeAssign(target, value);
                        try self.statements.append(self.allocator, stmt);
                    }
                },
                .RETURN_VALUE => {
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeReturn(value);
                        try self.statements.append(self.allocator, stmt);
                    }
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const constant = try sim.objToConstant(obj);
                        const value = try ast.makeConstant(self.allocator, constant);
                        const stmt = try self.makeReturn(value);
                        try self.statements.append(self.allocator, stmt);
                    }
                },
                .POP_TOP => {
                    // Expression statement (result discarded)
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeExprStmt(value);
                        try self.statements.append(self.allocator, stmt);
                    }
                },
                else => {
                    // Simulate the instruction to build up expressions
                    sim.simulate(inst) catch {};
                },
            }
        }
    }

    /// Decompile a range of blocks into a statement list.
    /// Returns statements from start_block up to (but not including) end_block.
    fn decompileBlockRange(self: *Decompiler, start_block: u32, end_block: ?u32) ![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var block_idx = start_block;
        const limit = end_block orelse @as(u32, @intCast(self.cfg.blocks.len));

        while (block_idx < limit) {
            // Process this block's statements
            try self.decompileBlockInto(block_idx, &stmts);
            block_idx += 1;
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    /// Decompile a single block's statements into the provided list.
    fn decompileBlockInto(self: *Decompiler, block_id: u32, stmts: *std.ArrayList(*Stmt)) !void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .STORE_NAME, .STORE_FAST, .STORE_GLOBAL => {
                    if (sim.stack.popExpr()) |value| {
                        const name = switch (inst.opcode) {
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                            .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                            else => "<unknown>",
                        };
                        const target = try ast.makeName(self.allocator, name, .store);
                        const stmt = try self.makeAssign(target, value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .RETURN_VALUE => {
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const constant = try sim.objToConstant(obj);
                        const value = try ast.makeConstant(self.allocator, constant);
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .POP_TOP => {
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeExprStmt(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                else => {
                    sim.simulate(inst) catch {};
                },
            }
        }
    }

    /// Decompile an if statement pattern.
    fn decompileIf(self: *Decompiler, pattern: ctrl.IfPattern) !?*Stmt {
        const cond_block = &self.cfg.blocks[pattern.condition_block];

        // Get the condition expression from the last instruction before the jump
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        // Simulate up to but not including the conditional jump
        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            sim.simulate(inst) catch {};
        }

        const condition = sim.stack.popExpr() orelse {
            return null;
        };

        // Decompile the then body
        const then_end = pattern.else_block orelse pattern.merge_block;
        const then_body = try self.decompileBlockRange(pattern.then_block, then_end);

        // Decompile the else body
        const else_body = if (pattern.else_block) |else_id| blk: {
            // Check if else is an elif
            if (pattern.is_elif) {
                // The else block is another if statement - recurse
                const else_pattern = self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    const elif_stmt = try self.decompileIf(else_pattern.if_stmt);
                    if (elif_stmt) |s| {
                        const body = try self.allocator.alloc(*Stmt, 1);
                        body[0] = s;
                        break :blk body;
                    }
                }
            }
            // Regular else
            break :blk try self.decompileBlockRange(else_id, pattern.merge_block);
        } else &[_]*Stmt{};

        // Create if statement
        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .if_stmt = .{
            .condition = condition,
            .body = then_body,
            .else_body = else_body,
        } };

        return stmt;
    }

    /// Decompile a while loop pattern.
    fn decompileWhile(self: *Decompiler, pattern: ctrl.WhilePattern) !?*Stmt {
        const header = &self.cfg.blocks[pattern.header_block];

        // Get the condition expression
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (header.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            sim.simulate(inst) catch {};
        }

        const condition = sim.stack.popExpr() orelse {
            // Use True as fallback
            return null;
        };

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .while_stmt = .{
            .condition = condition,
            .body = &.{}, // TODO: decompile body
            .else_body = &.{},
        } };

        return stmt;
    }

    /// Decompile a for loop pattern.
    fn decompileFor(self: *Decompiler, pattern: ctrl.ForPattern) !?*Stmt {
        _ = pattern;

        // For loops need the iterator expression and target
        // This requires more complex analysis

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .for_stmt = .{
            .target = try ast.makeName(self.allocator, "_", .store),
            .iter = try ast.makeName(self.allocator, "iter", .load),
            .body = &.{},
            .else_body = &.{},
            .type_comment = null,
            .is_async = false,
        } };

        return stmt;
    }

    /// Create an assignment statement.
    fn makeAssign(self: *Decompiler, target: *Expr, value: *Expr) !*Stmt {
        const targets = try self.allocator.alloc(*Expr, 1);
        targets[0] = target;

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .assign = .{
            .targets = targets,
            .value = value,
            .type_comment = null,
        } };
        return stmt;
    }

    /// Create a return statement.
    fn makeReturn(self: *Decompiler, value: *Expr) !*Stmt {
        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .return_stmt = .{
            .value = value,
        } };
        return stmt;
    }

    /// Create an expression statement.
    fn makeExprStmt(self: *Decompiler, value: *Expr) !*Stmt {
        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .expr_stmt = .{
            .value = value,
        } };
        return stmt;
    }

    /// Check if a statement is `return None`.
    pub fn isReturnNone(stmt: *const Stmt) bool {
        if (stmt.* != .return_stmt) return false;
        const ret = stmt.return_stmt;
        if (ret.value) |val| {
            if (val.* == .constant) {
                return val.constant == .none;
            }
        }
        return false;
    }
};

/// Decompile a code object and write Python source to writer.
pub fn decompileToSource(allocator: Allocator, code: *const pyc.Code, version: Version, writer: anytype) !void {
    // Handle module-level code
    if (std.mem.eql(u8, code.name, "<module>")) {
        // Process imports first (TODO)

        // Process function/class definitions
        for (code.consts) |c| {
            if (c == .code) {
                try decompileFunctionToSource(allocator, c.code, version, writer, 0);
                try writer.writeByte('\n');
            }
        }
    } else {
        try decompileFunctionToSource(allocator, code, version, writer, 0);
    }
}

/// Decompile a function and write to writer.
fn decompileFunctionToSource(allocator: Allocator, code: *const pyc.Code, version: Version, writer: anytype, indent: u32) !void {
    // Write indent
    var i: u32 = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("    ");
    }

    // Check for lambda
    if (codegen.isLambda(code)) {
        try writer.writeAll("# lambda\n");
        return;
    }

    // Write decorators (TODO: extract from bytecode)

    // Write async if coroutine
    if (codegen.isCoroutine(code)) {
        try writer.writeAll("async ");
    }

    // Write function signature
    try writer.writeAll("def ");
    try writer.writeAll(code.name);
    try writer.writeByte('(');

    // Write arguments
    var first = true;
    const posonly = code.posonlyargcount;
    const argcount = code.argcount;
    const kwonly = code.kwonlyargcount;

    // Position-only and regular args
    for (code.varnames[0..@min(argcount, code.varnames.len)], 0..) |name, idx| {
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.writeAll(name);

        if (posonly > 0 and idx == posonly - 1) {
            try writer.writeAll(", /");
        }
    }

    // Keyword-only args
    if (kwonly > 0 and argcount + kwonly <= code.varnames.len) {
        if (posonly == 0 and argcount > 0) {
            try writer.writeAll(", ");
        }
        if (argcount == posonly) {
            try writer.writeAll("*, ");
        }
        for (code.varnames[argcount .. argcount + kwonly], 0..) |name, idx| {
            if (idx > 0 or argcount > 0) try writer.writeAll(", ");
            try writer.writeAll(name);
        }
    }

    try writer.writeAll("):\n");

    // Write docstring
    if (codegen.extractDocstring(code)) |doc| {
        i = 0;
        while (i < indent + 1) : (i += 1) {
            try writer.writeAll("    ");
        }
        try writer.writeAll("\"\"\"");
        // Escape newlines in docstring
        for (doc) |c| {
            if (c == '\n') {
                try writer.writeByte('\n');
                var j: u32 = 0;
                while (j < indent + 1) : (j += 1) {
                    try writer.writeAll("    ");
                }
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeAll("\"\"\"\n");
    }

    // Decompile function body
    if (code.code.len > 0) {
        var decompiler = try Decompiler.init(allocator, code, version);
        defer decompiler.deinit();

        const stmts = try decompiler.decompile();

        // Filter out trailing `return None` (implicit in Python)
        var effective_stmts = stmts;
        while (effective_stmts.len > 0 and Decompiler.isReturnNone(effective_stmts[effective_stmts.len - 1])) {
            effective_stmts = effective_stmts[0 .. effective_stmts.len - 1];
        }

        if (effective_stmts.len == 0) {
            // Empty body - write pass
            i = 0;
            while (i < indent + 1) : (i += 1) {
                try writer.writeAll("    ");
            }
            try writer.writeAll("pass\n");
        } else {
            // Write decompiled statements
            var cg = codegen.Writer.init(allocator);
            defer cg.deinit(allocator);
            cg.indent_level = indent + 1;

            for (effective_stmts) |stmt| {
                try cg.writeStmt(allocator, stmt);
            }

            const output = try cg.getOutput(allocator);
            defer allocator.free(output);
            try writer.writeAll(output);
        }
    } else {
        i = 0;
        while (i < indent + 1) : (i += 1) {
            try writer.writeAll("    ");
        }
        try writer.writeAll("pass\n");
    }

    // Process nested functions
    for (code.consts) |c| {
        if (c == .code) {
            const nested = c.code;
            if (!std.mem.eql(u8, nested.name, "<lambda>")) {
                try writer.writeByte('\n');
                try decompileFunctionToSource(allocator, nested, version, writer, indent + 1);
            }
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "decompiler init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create minimal code object
    var code = pyc.Code{
        .allocator = allocator,
        .name = "test",
        .code = &.{},
    };

    const version = Version.init(3, 12);

    var decompiler = try Decompiler.init(allocator, &code, version);
    defer decompiler.deinit();

    try testing.expectEqual(@as(usize, 0), decompiler.cfg.blocks.len);
}
