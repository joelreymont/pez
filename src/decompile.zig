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
const dom_mod = @import("dom.zig");
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
const StackValue = stack_mod.StackValue;
const Opcode = decoder.Opcode;
pub const DecompileError = stack_mod.SimError || error{ UnexpectedEmptyWorklist, InvalidBlock };

/// Decompiler state for a single code object.
pub const Decompiler = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    code: *const pyc.Code,
    version: Version,
    cfg: *CFG,
    analyzer: Analyzer,
    dom: dom_mod.DomTree,

    /// Accumulated statements.
    statements: std.ArrayList(*Stmt),
    /// Nested decompilers (kept alive for arena lifetime).
    nested_decompilers: std.ArrayList(*Decompiler),

    pub fn init(allocator: Allocator, code: *const pyc.Code, version: Version) DecompileError!Decompiler {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const a = arena.allocator();

        // Allocate CFG on heap so pointer stays valid
        const cfg = try a.create(CFG);

        cfg.* = if (version.gte(3, 11) and code.exceptiontable.len > 0)
            try cfg_mod.buildCFGWithExceptions(a, code.code, code.exceptiontable, version)
        else
            try cfg_mod.buildCFG(a, code.code, version);
        errdefer cfg.deinit();

        var analyzer = try Analyzer.init(allocator, cfg);
        errdefer analyzer.deinit();

        var dom = try dom_mod.DomTree.init(allocator, cfg);
        errdefer dom.deinit();

        return .{
            .allocator = allocator,
            .arena = arena,
            .code = code,
            .version = version,
            .cfg = cfg,
            .analyzer = analyzer,
            .dom = dom,
            .statements = .{},
            .nested_decompilers = .{},
        };
    }

    pub fn deinit(self: *Decompiler) void {
        for (self.nested_decompilers.items) |nested| {
            nested.deinit();
            self.allocator.destroy(nested);
        }
        self.nested_decompilers.deinit(self.allocator);
        self.analyzer.deinit();
        self.dom.deinit();
        self.arena.deinit();
        self.statements.deinit(self.allocator);
    }

    fn isStatementOpcode(op: Opcode) bool {
        const name = op.name();
        return std.mem.startsWith(u8, name, "STORE_") or
            std.mem.startsWith(u8, name, "DELETE_") or
            std.mem.startsWith(u8, name, "IMPORT_") or
            std.mem.startsWith(u8, name, "RETURN_") or
            std.mem.startsWith(u8, name, "RAISE_") or
            std.mem.startsWith(u8, name, "PRINT_") or
            std.mem.startsWith(u8, name, "EXEC_") or
            std.mem.eql(u8, name, "POP_TOP") or
            std.mem.eql(u8, name, "RERAISE") or
            std.mem.eql(u8, name, "SETUP_EXCEPT") or
            std.mem.eql(u8, name, "SETUP_FINALLY") or
            std.mem.eql(u8, name, "SETUP_WITH") or
            std.mem.eql(u8, name, "SETUP_ASYNC_WITH") or
            std.mem.eql(u8, name, "END_FINALLY") or
            std.mem.eql(u8, name, "WITH_CLEANUP") or
            std.mem.eql(u8, name, "POP_BLOCK") or
            std.mem.eql(u8, name, "POP_EXCEPT") or
            std.mem.eql(u8, name, "BREAK_LOOP") or
            std.mem.eql(u8, name, "CONTINUE_LOOP") or
            std.mem.eql(u8, name, "YIELD_VALUE") or
            std.mem.eql(u8, name, "YIELD_FROM") or
            std.mem.eql(u8, name, "END_FOR") or
            std.mem.eql(u8, name, "END_SEND");
    }

    fn deinitStackValuesSlice(allocator: Allocator, values: []StackValue) void {
        for (values) |val| {
            val.deinit(allocator);
        }
        if (values.len > 0) allocator.free(values);
    }

    fn cloneStackValues(
        self: *Decompiler,
        sim: *SimContext,
        values: []const StackValue,
    ) DecompileError![]StackValue {
        const out = try self.allocator.alloc(StackValue, values.len);
        var count: usize = 0;
        errdefer {
            for (out[0..count]) |val| {
                val.deinit(self.allocator);
            }
            self.allocator.free(out);
        }

        for (values, 0..) |val, idx| {
            out[idx] = try sim.cloneStackValue(val);
            count += 1;
        }

        return out;
    }

    fn moveStackValuesToSim(
        self: *Decompiler,
        sim: *SimContext,
        values: []StackValue,
    ) DecompileError!void {
        var moved: usize = 0;
        errdefer {
            for (values[moved..]) |val| {
                val.deinit(self.allocator);
            }
        }

        for (values) |val| {
            try sim.stack.push(val);
            moved += 1;
        }
    }

    fn processBlockWithSim(
        self: *Decompiler,
        block: *const BasicBlock,
        sim: *SimContext,
        stmts: *std.ArrayList(*Stmt),
    ) DecompileError!void {
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .STORE_NAME, .STORE_FAST, .STORE_GLOBAL => {
                    const name = switch (inst.opcode) {
                        .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                        .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                        else => "<unknown>",
                    };
                    const value = sim.stack.pop() orelse return error.StackUnderflow;
                    errdefer value.deinit(self.allocator);
                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .RETURN_VALUE => {
                    const value = try sim.stack.popExpr();
                    const stmt = try self.makeReturn(value);
                    try stmts.append(self.allocator, stmt);
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const value = try sim.objToExpr(obj);
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .POP_TOP => {
                    const value = try sim.stack.popExpr();
                    const stmt = try self.makeExprStmt(value);
                    try stmts.append(self.allocator, stmt);
                },
                .END_FOR, .POP_ITER => {
                    // Loop cleanup opcodes - skip in non-loop context
                },
                else => {
                    try sim.simulate(inst);
                },
            }
        }
    }

    fn simulateTernaryBranch(
        self: *Decompiler,
        block_id: u32,
        base_vals: []const StackValue,
    ) DecompileError!?*Expr {
        if (block_id >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[block_id];

        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (base_vals) |val| {
            try sim.stack.push(try sim.cloneStackValue(val));
        }

        for (block.instructions) |inst| {
            if (inst.isConditionalJump()) return null;
            if (inst.isUnconditionalJump()) break;
            if (isStatementOpcode(inst.opcode)) return null;
            try sim.simulate(inst);
        }

        if (sim.stack.len() != base_vals.len + 1) return null;
        const expr = sim.stack.popExpr() catch return null;
        return expr;
    }

    fn tryDecompileTernaryInto(
        self: *Decompiler,
        block_id: u32,
        limit: u32,
        stmts: *std.ArrayList(*Stmt),
    ) DecompileError!?u32 {
        const pattern = self.analyzer.detectTernary(block_id) orelse return null;
        if (pattern.true_block >= limit or pattern.false_block >= limit or pattern.merge_block >= limit) {
            return null;
        }
        if (pattern.merge_block <= block_id) return null;
        if ((try self.analyzer.detectPattern(pattern.merge_block)) != .unknown) return null;

        var condition: *Expr = undefined;
        var condition_owned = false;
        var base_vals: []StackValue = &.{};
        var base_owned = false;
        var true_expr: *Expr = undefined;
        var true_owned = false;
        var false_expr: *Expr = undefined;
        var false_owned = false;
        var if_expr: *Expr = undefined;
        var if_owned = false;

        defer {
            if (if_owned) {
                if_expr.deinit(self.allocator);
                self.allocator.destroy(if_expr);
            }
            if (false_owned) {
                false_expr.deinit(self.allocator);
                self.allocator.destroy(false_expr);
            }
            if (true_owned) {
                true_expr.deinit(self.allocator);
                self.allocator.destroy(true_expr);
            }
            if (condition_owned) {
                condition.deinit(self.allocator);
                self.allocator.destroy(condition);
            }
            if (base_owned) {
                deinitStackValuesSlice(self.allocator, base_vals);
            }
        }

        const cond_block = &self.cfg.blocks[pattern.condition_block];
        var cond_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer cond_sim.deinit();

        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (isStatementOpcode(inst.opcode)) return null;
            try cond_sim.simulate(inst);
        }

        condition = cond_sim.stack.popExpr() catch return null;
        condition_owned = true;

        base_vals = try self.cloneStackValues(&cond_sim, cond_sim.stack.items.items);
        base_owned = true;

        const true_opt = try self.simulateTernaryBranch(pattern.true_block, base_vals);
        if (true_opt == null) return null;
        true_expr = true_opt.?;
        true_owned = true;

        const false_opt = try self.simulateTernaryBranch(pattern.false_block, base_vals);
        if (false_opt == null) return null;
        false_expr = false_opt.?;
        false_owned = true;

        const a = self.arena.allocator();
        if_expr = try a.create(Expr);
        if_owned = true;
        if_expr.* = .{ .if_exp = .{
            .condition = condition,
            .body = true_expr,
            .else_body = false_expr,
        } };

        condition_owned = false;
        true_owned = false;
        false_owned = false;

        var merge_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer merge_sim.deinit();

        base_owned = false;
        errdefer self.allocator.free(base_vals);
        try self.moveStackValuesToSim(&merge_sim, base_vals);
        self.allocator.free(base_vals);

        try merge_sim.stack.push(.{ .expr = if_expr });
        if_owned = false;

        const merge_block = &self.cfg.blocks[pattern.merge_block];
        try self.processBlockWithSim(merge_block, &merge_sim, stmts);

        return pattern.merge_block + 1;
    }

    /// Find the last block that's part of an if-elif-else chain.
    fn findIfChainEnd(self: *Decompiler, pattern: ctrl.IfPattern) DecompileError!u32 {
        var max_block = pattern.then_block;

        if (pattern.else_block) |else_id| {
            max_block = @max(max_block, else_id);

            // If this is an elif, recursively find its end
            if (pattern.is_elif) {
                const else_pattern = try self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    max_block = @max(max_block, try self.findIfChainEnd(else_pattern.if_stmt));
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
    pub fn decompile(self: *Decompiler) DecompileError![]const *Stmt {
        if (self.cfg.blocks.len == 0) {
            return self.statements.items;
        }

        // Process blocks in order, using control flow patterns
        var block_idx: u32 = 0;
        while (block_idx < self.cfg.blocks.len) {
            if (try self.tryDecompileTernaryInto(
                block_idx,
                @intCast(self.cfg.blocks.len),
                &self.statements,
            )) |next_block| {
                block_idx = next_block;
                continue;
            }
            const pattern = try self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    const stmt = try self.decompileIf(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    // Skip all processed blocks
                    block_idx = try self.findIfChainEnd(p);
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
                .try_stmt => |p| {
                    const result = try self.decompileTry(p);
                    if (result.stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                .with_stmt => |p| {
                    const result = try self.decompileWith(p);
                    if (result.stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                else => {
                    const block = &self.cfg.blocks[block_idx];
                    // Skip exception handler blocks - they're decompiled as part of try/except
                    if (block.is_exception_handler or self.hasExceptionHandlerOpcodes(block)) {
                        block_idx += 1;
                        continue;
                    }
                    // Process block as sequential statements
                    try self.decompileBlock(block_idx);
                    block_idx += 1;
                },
            }
        }

        return self.statements.items;
    }

    /// Decompile a single basic block into statements.
    fn decompileBlock(self: *Decompiler, block_id: u32) DecompileError!void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        try self.processBlockWithSim(block, &sim, &self.statements);
    }

    /// Decompile a range of blocks into a statement list.
    /// Returns statements from start_block up to (but not including) end_block.
    fn decompileBlockRange(self: *Decompiler, start_block: u32, end_block: ?u32) DecompileError![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var block_idx = start_block;
        const limit = end_block orelse @as(u32, @intCast(self.cfg.blocks.len));

        while (block_idx < limit) {
            // Process this block's statements
            if (try self.tryDecompileTernaryInto(block_idx, limit, &stmts)) |next_block| {
                block_idx = next_block;
                continue;
            }
            try self.decompileBlockInto(block_idx, &stmts);
            block_idx += 1;
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    /// Decompile a single block's statements into the provided list.
    fn decompileBlockInto(self: *Decompiler, block_id: u32, stmts: *std.ArrayList(*Stmt)) DecompileError!void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        try self.processBlockWithSim(block, &sim, stmts);
    }

    /// Decompile an if statement pattern.
    fn decompileIf(self: *Decompiler, pattern: ctrl.IfPattern) DecompileError!?*Stmt {
        const cond_block = &self.cfg.blocks[pattern.condition_block];

        // Get the condition expression from the last instruction before the jump
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        // Simulate up to but not including the conditional jump
        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            try sim.simulate(inst);
        }

        const condition = try sim.stack.popExpr();

        // Decompile the then body
        const then_end = pattern.else_block orelse pattern.merge_block;
        const then_body_tmp = try self.decompileBlockRange(pattern.then_block, then_end);
        defer self.allocator.free(then_body_tmp);
        const a = self.arena.allocator();
        const then_body = try a.dupe(*Stmt, then_body_tmp);

        // Decompile the else body
        const else_body = if (pattern.else_block) |else_id| blk: {
            // Check if else is an elif
            if (pattern.is_elif) {
                // The else block is another if statement - recurse
                const else_pattern = try self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    const elif_stmt = try self.decompileIf(else_pattern.if_stmt);
                    if (elif_stmt) |s| {
                        const body = try a.alloc(*Stmt, 1);
                        body[0] = s;
                        break :blk body;
                    }
                }
            }
            // Regular else
            const else_body_tmp = try self.decompileBlockRange(else_id, pattern.merge_block);
            defer self.allocator.free(else_body_tmp);
            break :blk try a.dupe(*Stmt, else_body_tmp);
        } else &[_]*Stmt{};

        // Create if statement
        const stmt = try a.create(Stmt);
        stmt.* = .{ .if_stmt = .{
            .condition = condition,
            .body = then_body,
            .else_body = else_body,
        } };

        return stmt;
    }

    /// Decompile a while loop pattern.
    fn decompileWhile(self: *Decompiler, pattern: ctrl.WhilePattern) DecompileError!?*Stmt {
        const header = &self.cfg.blocks[pattern.header_block];

        // Get the condition expression
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (header.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            try sim.simulate(inst);
        }

        const condition = try sim.stack.popExpr();

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer visited.deinit();

        var skip_first = false;
        const body = try self.decompileLoopBody(
            pattern.body_block,
            pattern.header_block,
            &skip_first,
            &visited,
            null,
        );

        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .{
            .while_stmt = .{
                .condition = condition,
                .body = body,
                .else_body = &.{},
            },
        };

        return stmt;
    }

    const PatternResult = struct {
        stmt: ?*Stmt,
        next_block: u32,
    };

    fn decompileTry(self: *Decompiler, pattern: ctrl.TryPattern) DecompileError!PatternResult {
        defer self.allocator.free(pattern.handlers);

        var handler_blocks: std.ArrayList(u32) = .{};
        defer handler_blocks.deinit(self.allocator);

        for (pattern.handlers) |handler| {
            if (handler.handler_block >= self.cfg.blocks.len) continue;
            try handler_blocks.append(self.allocator, handler.handler_block);
        }
        if (handler_blocks.items.len == 0) {
            return .{ .stmt = null, .next_block = pattern.try_block + 1 };
        }

        // TODO: Fix try/except decompilation for Python 3.11+
        // Current implementation has issues with exception table-based exception handling.
        // Skip try/except decompilation and just process blocks sequentially.
        std.mem.sort(u32, handler_blocks.items, {}, std.sort.asc(u32));
        const max_handler = handler_blocks.items[handler_blocks.items.len - 1];
        return .{ .stmt = null, .next_block = max_handler + 1 };

        // DISABLED CODE - needs fixing for 3.11+ exception tables
        // std.mem.sort(u32, handler_blocks.items, {}, std.sort.asc(u32));
        //
        //         var handler_set = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        //         defer handler_set.deinit();
        //         for (handler_blocks.items) |hid| {
        //             handler_set.set(hid);
        //         }
        //
        //         var protected_set = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        //         defer protected_set.deinit();
        //         for (self.cfg.blocks, 0..) |block, i| {
        //             for (block.successors) |edge| {
        //                 if (edge.edge_type == .exception and handler_set.isSet(edge.target)) {
        //                     protected_set.set(i);
        //                     break;
        //                 }
        //             }
        //         }
        //
        //         var post_try_entry: ?u32 = null;
        //         for (self.cfg.blocks, 0..) |block, i| {
        //             if (!protected_set.isSet(i)) continue;
        //             for (block.successors) |edge| {
        //                 if (edge.edge_type == .exception) continue;
        //                 if (edge.target >= self.cfg.blocks.len) continue;
        //                 if (protected_set.isSet(edge.target)) continue;
        //                 if (handler_set.isSet(edge.target)) continue;
        //                 post_try_entry = if (post_try_entry) |prev|
        //                     @min(prev, edge.target)
        //                 else
        //                     edge.target;
        //             }
        //         }
        //
        //         var handler_reach = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        //         defer handler_reach.deinit();
        //         for (handler_blocks.items) |hid| {
        //             var reach = try self.collectReachableNoException(hid, &handler_set);
        //             defer reach.deinit();
        //             handler_reach.setUnion(reach);
        //         }
        //
        //         std.debug.print("Computing join_block, post_try_entry={?}\n", .{post_try_entry});
        //         var join_block: ?u32 = null;
        //         if (post_try_entry) |entry| {
        //             var normal_reach = try self.collectReachableNoException(entry, &handler_set);
        //             defer normal_reach.deinit();
        //             var it = normal_reach.iterator(.{});
        //             while (it.next()) |bit| {
        //                 if (handler_reach.isSet(bit)) {
        //                     join_block = @intCast(bit);
        //                     break;
        //                 }
        //             }
        //         }
        //         std.debug.print("join_block={?}\n", .{join_block});
        //
        //         var has_finally = false;
        //         for (handler_blocks.items) |hid| {
        //             if (self.isFinallyHandler(hid)) {
        //                 has_finally = true;
        //                 break;
        //             }
        //         }
        //
        //         var else_start: ?u32 = null;
        //         if (post_try_entry) |entry| {
        //             if (!handler_reach.isSet(entry)) {
        //                 if (join_block == null or entry != join_block.?) {
        //                     else_start = entry;
        //                 }
        //             }
        //         }
        //
        //         var finally_start: ?u32 = null;
        //         if (has_finally) {
        //             finally_start = join_block orelse post_try_entry;
        //         }
        //
        //         const handler_start = handler_blocks.items[0];
        //         var try_end: u32 = handler_start;
        //         if (else_start) |start| {
        //             if (start < try_end) try_end = start;
        //         }
        //         if (finally_start) |start| {
        //             if (start < try_end) try_end = start;
        //         }
        //
        //         const try_body = if (pattern.try_block < try_end and pattern.try_block != try_end)
        //             try self.decompileStructuredRange(pattern.try_block, try_end)
        //         else
        //             &[_]*Stmt{};
        //
        //         var else_end: u32 = handler_start;
        //         if (else_start) |start| {
        //             if (finally_start) |final_start| {
        //                 if (final_start > start and final_start < else_end) else_end = final_start;
        //             }
        //             if (join_block) |join| {
        //                 if (join > start and join < else_end) else_end = join;
        //             }
        //         }
        //
        //         const else_body = if (else_start) |start| blk: {
        //             if (start >= else_end) break :blk &[_]*Stmt{};
        //             break :blk try self.decompileStructuredRange(start, else_end);
        //         } else &[_]*Stmt{};
        //
        //         var final_end: u32 = pattern.exit_block orelse @as(u32, @intCast(self.cfg.blocks.len));
        //         if (finally_start) |final_start| {
        //             if (handler_start > final_start and handler_start < final_end) {
        //                 final_end = handler_start;
        //             }
        //         }
        //
        //         const final_body = if (finally_start) |start| blk: {
        //             if (start >= final_end) break :blk &[_]*Stmt{};
        //             break :blk try self.decompileStructuredRange(start, final_end);
        //         } else &[_]*Stmt{};
        //
        //         var handler_nodes = try self.allocator.alloc(ast.ExceptHandler, handler_blocks.items.len);
        //         errdefer {
        //             for (handler_nodes) |*h| {
        //                 if (h.type) |t| {
        //                     t.deinit(self.allocator);
        //                     self.allocator.destroy(t);
        //                 }
        //                 if (h.body.len > 0) self.allocator.free(h.body);
        //             }
        //             self.allocator.free(handler_nodes);
        //         }
        //
        //         for (handler_blocks.items, 0..) |hid, idx| {
        //             std.debug.print("Processing handler {}: id={}\n", .{idx, hid});
        //             const handler_end = blk: {
        //                 const next_handler = if (idx + 1 < handler_blocks.items.len)
        //                     handler_blocks.items[idx + 1]
        //                 else
        //                     (pattern.exit_block orelse @as(u32, @intCast(self.cfg.blocks.len)));
        //                 if (finally_start) |start| {
        //                     if (start > hid and start < next_handler) break :blk start;
        //                 }
        //                 break :blk next_handler;
        //             };
        //             std.debug.print("handler_end={}\n", .{handler_end});
        //
        //             const info = try self.extractHandlerHeader(hid);
        //             const body = try self.decompileHandlerBody(hid, handler_end, info.skip_first_store);
        //             handler_nodes[idx] = .{
        //                 .type = info.exc_type,
        //                 .name = info.name,
        //                 .body = body,
        //             };
        //         }
        //
        //         const a = self.arena.allocator();
        //         const stmt = try a.create(Stmt);
        //         stmt.* = .{
        //             .try_stmt = .{
        //                 .body = try_body,
        //                 .handlers = handler_nodes,
        //                 .else_body = else_body,
        //                 .finalbody = final_body,
        //             },
        //         };
        //
        //         std.debug.print("final_end={}, try_end={}, else_start={?}, exit={?}\n", .{final_end, try_end, else_start, pattern.exit_block});
        //         var next_block: u32 = final_end;
        //         if (next_block < try_end) next_block = try_end;
        //         if (else_start) |start| {
        //             if (start > next_block) next_block = start;
        //         }
        //         if (pattern.exit_block) |exit| {
        //             if (exit > next_block) next_block = exit;
        //         }
        //
        //         // Ensure forward progress - must advance past all handlers
        //         const last_handler = handler_blocks.items[handler_blocks.items.len - 1];
        //         if (next_block <= last_handler) {
        //             next_block = last_handler + 1;
        //         }
        //
        //         std.debug.print("next_block={}\n", .{next_block});
        //         return .{ .stmt = stmt, .next_block = next_block };
    }

    fn decompileWith(self: *Decompiler, pattern: ctrl.WithPattern) DecompileError!PatternResult {
        const setup = &self.cfg.blocks[pattern.setup_block];
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        var after_before_with = false;
        var is_async = false;
        var optional_vars: ?*Expr = null;

        for (setup.instructions) |inst| {
            if (inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH) {
                after_before_with = true;
                if (inst.opcode == .BEFORE_ASYNC_WITH) {
                    is_async = true;
                }
                continue;
            }
            if (!after_before_with) {
                try sim.simulate(inst);
                continue;
            }

            switch (inst.opcode) {
                .STORE_FAST => {
                    if (sim.getLocal(inst.arg)) |name| {
                        optional_vars = try ast.makeName(self.allocator, name, .store);
                    }
                    break;
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    if (sim.getName(inst.arg)) |name| {
                        optional_vars = try ast.makeName(self.allocator, name, .store);
                    }
                    break;
                },
                else => {},
            }
        }

        const context_expr = try sim.stack.popExpr();

        const item = try self.allocator.alloc(ast.WithItem, 1);
        item[0] = .{
            .context_expr = context_expr,
            .optional_vars = optional_vars,
        };

        const body = try self.decompileStructuredRange(pattern.body_block, pattern.cleanup_block);

        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .{
            .with_stmt = .{
                .items = item,
                .body = body,
                .type_comment = null,
                .is_async = is_async,
            },
        };

        return .{ .stmt = stmt, .next_block = pattern.exit_block };
    }

    fn decompileStructuredRange(self: *Decompiler, start: u32, end: u32) DecompileError![]const *Stmt {
        // Handle empty range (start == end)
        if (start >= end) return &[_]*Stmt{};

        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var block_idx = start;
        const limit = @min(end, @as(u32, @intCast(self.cfg.blocks.len)));

        while (block_idx < limit) {
            const pattern = try self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    const stmt = try self.decompileIf(p);
                    if (stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = try self.findIfChainEnd(p);
                },
                .while_loop => |p| {
                    const stmt = try self.decompileWhile(p);
                    if (stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .for_loop => |p| {
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .try_stmt => |p| {
                    const result = try self.decompileTry(p);
                    if (result.stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                .with_stmt => |p| {
                    const result = try self.decompileWith(p);
                    if (result.stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                else => {
                    try self.decompileBlockInto(block_idx, &stmts);
                    block_idx += 1;
                },
            }
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    const HandlerHeader = struct {
        exc_type: ?*Expr,
        name: ?[]const u8,
        skip_first_store: bool,
    };

    fn extractHandlerHeader(self: *Decompiler, handler_block: u32) DecompileError!HandlerHeader {
        if (handler_block >= self.cfg.blocks.len) return error.InvalidBlock;
        const block = &self.cfg.blocks[handler_block];
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        var exc_type: ?*Expr = null;
        for (block.instructions) |inst| {
            if (inst.opcode == .CHECK_EXC_MATCH) {
                exc_type = try sim.stack.popExpr();
                break;
            }
            try sim.simulate(inst);
        }

        var name: ?[]const u8 = null;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .STORE_FAST => {
                    name = sim.getLocal(inst.arg);
                    break;
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    name = sim.getName(inst.arg);
                    break;
                },
                else => {},
            }
        }

        return .{
            .exc_type = exc_type,
            .name = name,
            .skip_first_store = name != null,
        };
    }

    fn decompileHandlerBody(
        self: *Decompiler,
        start: u32,
        end: u32,
        skip_first_store: bool,
    ) DecompileError![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        if (start >= end or start >= self.cfg.blocks.len) {
            return &[_]*Stmt{};
        }

        var skip_store = skip_first_store;
        try self.processBlockStatements(
            start,
            &self.cfg.blocks[start],
            &stmts,
            &skip_store,
            false,
            null,
        );

        if (start + 1 < end) {
            const rest = try self.decompileStructuredRange(start + 1, end);
            try stmts.appendSlice(self.allocator, rest);
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    fn collectReachableNoException(
        self: *Decompiler,
        start: u32,
        handler_set: *const std.DynamicBitSet,
    ) DecompileError!std.DynamicBitSet {
        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        var queue: std.ArrayList(u32) = .{};
        defer queue.deinit(self.allocator);

        if (start >= self.cfg.blocks.len) return visited;
        if (handler_set.isSet(start)) return visited;

        visited.set(start);
        try queue.append(self.allocator, start);

        while (queue.items.len > 0) {
            const node = queue.pop().?;
            const block = &self.cfg.blocks[node];
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (handler_set.isSet(edge.target)) continue;
                if (!visited.isSet(edge.target)) {
                    visited.set(edge.target);
                    try queue.append(self.allocator, edge.target);
                }
            }
        }

        return visited;
    }

    fn isFinallyHandler(self: *Decompiler, handler_block: u32) bool {
        const block = &self.cfg.blocks[handler_block];
        for (block.instructions) |inst| {
            if (inst.opcode == .CHECK_EXC_MATCH) return false;
        }
        for (block.instructions) |inst| {
            if (inst.opcode == .RERAISE) return true;
        }
        return false;
    }

    fn hasExceptionHandlerOpcodes(self: *Decompiler, block: *const BasicBlock) bool {
        _ = self;
        for (block.instructions) |inst| {
            if (inst.opcode == .PUSH_EXC_INFO or inst.opcode == .CHECK_EXC_MATCH or inst.opcode == .POP_EXCEPT) return true;
        }
        return false;
    }

    /// Decompile a for loop pattern.
    fn decompileFor(self: *Decompiler, pattern: ctrl.ForPattern) DecompileError!?*Stmt {
        // Get the iterator expression from the setup block
        // The setup block contains: ... GET_ITER
        // The expression before GET_ITER is the iterator
        const setup = &self.cfg.blocks[pattern.setup_block];

        var iter_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer iter_sim.deinit();

        for (setup.instructions) |inst| {
            if (inst.opcode == .GET_ITER) break;
            try iter_sim.simulate(inst);
        }

        const iter_expr = try iter_sim.stack.popExpr();

        // Get the loop target from the body block's first STORE_FAST
        const body = &self.cfg.blocks[pattern.body_block];
        var target_name: []const u8 = "_";

        for (body.instructions) |inst| {
            if (inst.opcode == .STORE_FAST) {
                if (self.code.varnames.len > inst.arg) {
                    target_name = self.code.varnames[inst.arg];
                }
                break;
            }
        }

        const target = try ast.makeName(self.allocator, target_name, .store);

        // Decompile the body (skip the first STORE_FAST which is the target)
        const body_stmts = try self.decompileForBody(pattern.body_block, pattern.header_block);

        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .{ .for_stmt = .{
            .target = target,
            .iter = iter_expr,
            .body = body_stmts,
            .else_body = &.{},
            .type_comment = null,
            .is_async = false,
        } };

        return stmt;
    }

    /// Decompile a for loop body using dominator-based loop membership.
    fn decompileForBody(self: *Decompiler, body_block_id: u32, header_block_id: u32) DecompileError![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer visited.deinit();

        var skip_first_store = true;
        var block_idx = body_block_id;

        while (block_idx < self.cfg.blocks.len) {
            // Use dominator tree to check loop membership
            if (!self.dom.isInLoop(block_idx, header_block_id)) break;

            const block = &self.cfg.blocks[block_idx];

            if (visited.isSet(block_idx)) {
                block_idx += 1;
                continue;
            }
            visited.set(block_idx);

            // Check for nested control flow patterns
            const pattern = try self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    // Process statements before the condition
                    try self.processPartialBlock(block, &stmts, &skip_first_store);

                    // Handle nested if
                    const if_stmt = try self.decompileLoopIf(p, header_block_id, &visited);
                    if (if_stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx += 1;
                    continue;
                },
                else => {
                    // Process block statements, stop at loop-back jump
                    const has_back_edge = self.hasLoopBackEdge(block, header_block_id);
                    try self.processBlockStatements(
                        block_idx,
                        block,
                        &stmts,
                        &skip_first_store,
                        has_back_edge,
                        header_block_id,
                    );
                    if (has_back_edge) break;
                    block_idx += 1;
                },
            }
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    /// Check if a block has a back edge to the loop header.
    fn hasLoopBackEdge(self: *Decompiler, block: *const cfg_mod.BasicBlock, header_id: u32) bool {
        _ = self;
        for (block.successors) |edge| {
            if (edge.edge_type == .loop_back and edge.target == header_id) {
                return true;
            }
        }
        return false;
    }

    /// Process statements in a block, stopping before control flow jumps.
    fn processBlockStatements(
        self: *Decompiler,
        block_id: u32,
        block: *const cfg_mod.BasicBlock,
        stmts: *std.ArrayList(*Stmt),
        skip_first_store: *bool,
        stop_at_jump: bool,
        loop_header: ?u32,
    ) DecompileError!void {
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .STORE_FAST => {
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        continue;
                    }
                    const name = sim.getLocal(inst.arg) orelse "<unknown>";
                    const value = sim.stack.pop() orelse return error.StackUnderflow;
                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        try sim.simulate(inst);
                        continue;
                    }
                    const name = sim.getName(inst.arg) orelse "<unknown>";
                    const value = sim.stack.pop() orelse return error.StackUnderflow;
                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .JUMP_FORWARD, .JUMP_BACKWARD, .JUMP_BACKWARD_NO_INTERRUPT, .JUMP_ABSOLUTE => {
                    if (loop_header) |header_id| {
                        const exit = self.analyzer.detectLoopExit(block_id, &[_]u32{header_id});
                        switch (exit) {
                            .break_stmt => {
                                const stmt = try self.makeBreak();
                                try stmts.append(self.allocator, stmt);
                                return;
                            },
                            .continue_stmt => {
                                const stmt = try self.makeContinue();
                                try stmts.append(self.allocator, stmt);
                                return;
                            },
                            else => {},
                        }
                    }
                    if (stop_at_jump) return;
                },
                .RETURN_VALUE => {
                    const value = try sim.stack.popExpr();
                    const stmt = try self.makeReturn(value);
                    try stmts.append(self.allocator, stmt);
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const value = try sim.objToExpr(obj);
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .POP_TOP => {
                    const value = try sim.stack.popExpr();
                    const stmt = try self.makeExprStmt(value);
                    try stmts.append(self.allocator, stmt);
                },
                else => {
                    try sim.simulate(inst);
                },
            }
        }
    }

    /// Process part of a block (before control flow instruction).
    fn processPartialBlock(
        self: *Decompiler,
        block: *const cfg_mod.BasicBlock,
        stmts: *std.ArrayList(*Stmt),
        skip_first_store: *bool,
    ) DecompileError!void {
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            // Stop at control flow instructions
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (inst.opcode == .JUMP_BACKWARD or inst.opcode == .JUMP_BACKWARD_NO_INTERRUPT) break;

            switch (inst.opcode) {
                .STORE_FAST => {
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        continue;
                    }
                    const name = sim.getLocal(inst.arg) orelse "<unknown>";
                    const value = sim.stack.pop() orelse return error.StackUnderflow;
                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(self.allocator, stmt);
                    }
                },
                else => {
                    try sim.simulate(inst);
                },
            }
        }
    }

    /// Decompile an if statement that's inside a loop.
    fn decompileLoopIf(
        self: *Decompiler,
        pattern: ctrl.IfPattern,
        loop_header: u32,
        visited: *std.DynamicBitSet,
    ) DecompileError!?*Stmt {
        const cond_block = &self.cfg.blocks[pattern.condition_block];

        // Get the condition expression
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            try sim.simulate(inst);
        }

        const condition = try sim.stack.popExpr();

        const then_in_loop = self.dom.isInLoop(pattern.then_block, loop_header);
        const else_in_loop = if (pattern.else_block) |else_id|
            self.dom.isInLoop(else_id, loop_header)
        else
            false;
        const merge_in_loop = if (pattern.merge_block) |merge_id|
            self.dom.isInLoop(merge_id, loop_header)
        else
            false;
        const else_is_continuation = else_in_loop and !then_in_loop and !merge_in_loop;

        // Decompile the then body
        var skip_first = false;
        const then_body = try self.decompileLoopBody(
            pattern.then_block,
            loop_header,
            &skip_first,
            visited,
            if (merge_in_loop) pattern.merge_block else null,
        );

        // Decompile the else body if present
        const else_body = if (pattern.else_block) |else_id| blk: {
            if (else_is_continuation) break :blk &[_]*Stmt{};
            if (pattern.is_elif) {
                const else_pattern = try self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    const elif_stmt = try self.decompileLoopIf(else_pattern.if_stmt, loop_header, visited);
                    if (elif_stmt) |s| {
                        const body = try self.allocator.alloc(*Stmt, 1);
                        body[0] = s;
                        break :blk body;
                    }
                }
            }
            var skip = false;
            break :blk try self.decompileLoopBody(
                else_id,
                loop_header,
                &skip,
                visited,
                if (merge_in_loop) pattern.merge_block else null,
            );
        } else &[_]*Stmt{};

        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .{ .if_stmt = .{
            .condition = condition,
            .body = then_body,
            .else_body = else_body,
        } };

        return stmt;
    }

    /// Decompile a body within a loop using dominator-based membership.
    fn decompileLoopBody(
        self: *Decompiler,
        start_block: u32,
        loop_header: u32,
        skip_first_store: *bool,
        visited: *std.DynamicBitSet,
        stop_block: ?u32,
    ) DecompileError![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var block_idx = start_block;

        while (block_idx < self.cfg.blocks.len) {
            if (stop_block) |stop_id| {
                if (block_idx == stop_id) break;
            }
            // Use dominator tree for membership check
            if (!self.dom.isInLoop(block_idx, loop_header)) break;
            if (visited.isSet(block_idx)) break;
            visited.set(block_idx);

            const block = &self.cfg.blocks[block_idx];
            const has_back_edge = self.hasLoopBackEdge(block, loop_header);
            const pattern = try self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    try self.processPartialBlock(block, &stmts, skip_first_store);

                    const if_stmt = try self.decompileLoopIf(p, loop_header, visited);
                    if (if_stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }

                    if (p.merge_block) |merge_id| {
                        if (stop_block) |stop_id| {
                            if (merge_id == stop_id) break;
                        }
                        if (!self.dom.isInLoop(merge_id, loop_header)) break;
                        block_idx = merge_id;
                        continue;
                    }

                    break;
                },
                else => {
                    // Process statements, stopping at back edge
                    try self.processBlockStatements(
                        block_idx,
                        block,
                        &stmts,
                        skip_first_store,
                        has_back_edge,
                        loop_header,
                    );
                    if (has_back_edge) break;

                    // Move to next block
                    if (block.successors.len == 0) break;

                    // Find the non-loop-back successor
                    var next_block: ?u32 = null;
                    for (block.successors) |edge| {
                        if (edge.edge_type != .loop_back) {
                            next_block = edge.target;
                            break;
                        }
                    }
                    if (next_block) |next_id| {
                        if (stop_block) |stop_id| {
                            if (next_id == stop_id) break;
                        }
                        block_idx = next_id;
                        continue;
                    }
                    break;
                },
            }
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    fn deinitExprSlice(self: *Decompiler, items: []const *Expr) void {
        _ = self;
        _ = items;
    }

    fn deinitStmtSlice(self: *Decompiler, items: []const *Stmt) void {
        _ = self;
        _ = items;
    }

    fn trimTrailingReturnNone(self: *Decompiler, items: []const *Stmt) DecompileError![]const *Stmt {
        if (items.len == 0) return items;

        var end = items.len;
        while (end > 0 and Decompiler.isReturnNone(items[end - 1])) {
            end -= 1;
        }

        if (end == items.len) return items;
        if (end == 0) return &.{};

        const a = self.arena.allocator();
        const trimmed = try a.alloc(*Stmt, end);
        @memcpy(trimmed, items[0..end]);
        return trimmed;
    }

    fn takeDecorators(self: *Decompiler, decorators: *std.ArrayList(*Expr)) DecompileError![]const *Expr {
        if (decorators.items.len == 0) return &.{};
        const count = decorators.items.len;
        const a = self.arena.allocator();
        const out = try a.alloc(*Expr, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            out[i] = decorators.items[count - 1 - i];
        }
        decorators.* = .{};
        return out;
    }

    fn decompileNestedBody(self: *Decompiler, code: *const pyc.Code) DecompileError![]const *Stmt {
        const nested_ptr = try self.allocator.create(Decompiler);
        errdefer self.allocator.destroy(nested_ptr);

        nested_ptr.* = try Decompiler.init(self.allocator, code, self.version);
        try self.nested_decompilers.append(self.allocator, nested_ptr);

        _ = try nested_ptr.decompile();
        const a = self.arena.allocator();
        const body = try a.dupe(*Stmt, nested_ptr.statements.items);
        return body;
    }

    fn makeFunctionDef(self: *Decompiler, name: []const u8, func: *stack_mod.FunctionValue) DecompileError!*Stmt {
        var cleanup_func = true;
        errdefer if (cleanup_func) func.deinit(self.allocator);

        const a = self.arena.allocator();

        var body = try self.decompileNestedBody(func.code);
        body = try self.trimTrailingReturnNone(body);

        // Extract docstring from consts[0] if it's a string
        if (func.code.consts.len > 0) {
            const first_const = &func.code.consts[0];
            if (first_const.* == .string) {
                const docstring = first_const.string;
                const doc_const = ast.Constant{ .string = docstring };
                const doc_expr = try ast.makeConstant(a, doc_const);
                const doc_stmt = try a.create(ast.Stmt);
                doc_stmt.* = .{ .expr_stmt = .{ .value = doc_expr } };

                // Prepend docstring to body
                const new_body = try a.alloc(*ast.Stmt, body.len + 1);
                new_body[0] = doc_stmt;
                @memcpy(new_body[1..], body);
                body = new_body;
            }
        }

        const args = try codegen.extractFunctionSignature(a, func.code, func.defaults, func.kw_defaults);

        const decorator_list = try self.takeDecorators(&func.decorators);

        cleanup_func = false;

        const name_copy = try a.dupe(u8, name);

        const stmt = try a.create(Stmt);

        stmt.* = .{ .function_def = .{
            .name = name_copy,
            .args = args,
            .body = body,
            .decorator_list = decorator_list,
            .returns = null,
            .type_comment = null,
            .is_async = codegen.isCoroutine(func.code) or codegen.isAsyncGenerator(func.code),
        } };

        return stmt;
    }

    fn makeClassDef(self: *Decompiler, name: []const u8, cls: *stack_mod.ClassValue) DecompileError!*Stmt {
        var cleanup_cls = true;
        errdefer if (cleanup_cls) cls.deinit(self.allocator);

        const a = self.arena.allocator();

        var body = try self.decompileNestedBody(cls.code);
        body = try self.trimTrailingReturnNone(body);

        // Extract class docstring from consts[1] if it's a string
        if (cls.code.consts.len > 1) {
            const second_const = &cls.code.consts[1];
            if (second_const.* == .string) {
                const docstring = second_const.string;
                const doc_const = ast.Constant{ .string = docstring };
                const doc_expr = try ast.makeConstant(a, doc_const);
                const doc_stmt = try a.create(ast.Stmt);
                doc_stmt.* = .{ .expr_stmt = .{ .value = doc_expr } };

                // Prepend docstring to body
                const new_body = try a.alloc(*ast.Stmt, body.len + 1);
                new_body[0] = doc_stmt;
                @memcpy(new_body[1..], body);
                body = new_body;
            }
        }

        const decorator_list = try self.takeDecorators(&cls.decorators);

        const bases = cls.bases;
        cls.bases = &.{};

        var class_name = name;
        if (cls.name.len > 0) {
            class_name = cls.name;
            cls.name = &.{};
        } else {
            class_name = try a.dupe(u8, name);
        }

        cleanup_cls = false;

        const stmt = try a.create(Stmt);
        stmt.* = .{ .class_def = .{
            .name = class_name,
            .bases = bases,
            .keywords = &.{},
            .body = body,
            .decorator_list = decorator_list,
        } };

        return stmt;
    }

    fn handleStoreValue(self: *Decompiler, name: []const u8, value: stack_mod.StackValue) DecompileError!?*Stmt {
        const a = self.arena.allocator();
        return switch (value) {
            .expr => |expr| blk: {
                const target = try ast.makeName(a, name, .store);
                break :blk try self.makeAssign(target, expr);
            },
            .function_obj => |func| try self.makeFunctionDef(name, func),
            .class_obj => |cls| try self.makeClassDef(name, cls),
            .import_module => |imp| try self.makeImport(name, imp),
            .saved_local => null,
            else => error.NotAnExpression,
        };
    }

    fn makeImport(self: *Decompiler, alias_name: []const u8, imp: stack_mod.ImportModule) DecompileError!*Stmt {
        const a = self.arena.allocator();
        const stmt = try a.create(ast.Stmt);

        if (imp.fromlist.len == 0) {
            // import module or import module as alias
            const asname = if (std.mem.eql(u8, alias_name, imp.module)) null else alias_name;
            const aliases = try a.alloc(ast.Alias, 1);
            aliases[0] = .{ .name = imp.module, .asname = asname };
            stmt.* = .{ .import_stmt = .{ .names = aliases } };
        } else {
            // from module import names
            const aliases = try a.alloc(ast.Alias, imp.fromlist.len);
            for (imp.fromlist, 0..) |from_name, i| {
                const asname = if (i == 0 and !std.mem.eql(u8, alias_name, from_name)) alias_name else null;
                aliases[i] = .{ .name = from_name, .asname = asname };
            }
            stmt.* = .{ .import_from = .{
                .module = imp.module,
                .names = aliases,
                .level = 0,
            } };
        }

        return stmt;
    }

    /// Create an assignment statement.
    fn makeAssign(self: *Decompiler, target: *Expr, value: *Expr) DecompileError!*Stmt {
        const a = self.arena.allocator();
        const targets = try a.alloc(*Expr, 1);
        targets[0] = target;

        const stmt = try a.create(Stmt);
        stmt.* = .{ .assign = .{
            .targets = targets,
            .value = value,
            .type_comment = null,
        } };
        return stmt;
    }

    /// Create a break statement.
    fn makeBreak(self: *Decompiler) DecompileError!*Stmt {
        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .break_stmt;
        return stmt;
    }

    /// Create a continue statement.
    fn makeContinue(self: *Decompiler) DecompileError!*Stmt {
        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .continue_stmt;
        return stmt;
    }

    /// Create a return statement.
    fn makeReturn(self: *Decompiler, value: *Expr) DecompileError!*Stmt {
        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .{ .return_stmt = .{
            .value = value,
        } };
        return stmt;
    }

    /// Create an expression statement.
    fn makeExprStmt(self: *Decompiler, value: *Expr) DecompileError!*Stmt {
        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
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
        var decompiler = try Decompiler.init(allocator, code, version);
        defer decompiler.deinit();

        const stmts = try decompiler.decompile();
        var effective_stmts = stmts;
        while (effective_stmts.len > 0 and Decompiler.isReturnNone(effective_stmts[effective_stmts.len - 1])) {
            effective_stmts = effective_stmts[0 .. effective_stmts.len - 1];
        }

        if (effective_stmts.len == 0) return;

        var cg = codegen.Writer.init(allocator);
        defer cg.deinit(allocator);

        for (effective_stmts) |stmt| {
            try cg.writeStmt(allocator, stmt);
        }

        const output = try cg.getOutput(allocator);
        defer allocator.free(output);
        try writer.writeAll(output);
        return;
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
        const lambda_expr = try stack_mod.buildLambdaExpr(allocator, code, version);
        defer {
            lambda_expr.deinit(allocator);
            allocator.destroy(lambda_expr);
        }

        var cg = codegen.Writer.init(allocator);
        defer cg.deinit(allocator);
        try cg.writeExpr(allocator, lambda_expr);
        const output = try cg.getOutput(allocator);
        defer allocator.free(output);
        try writer.writeAll(output);
        try writer.writeByte('\n');
        return;
    }

    // Decorators are emitted from module-level AST output.

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
