const std = @import("std");
const ast = @import("ast.zig");
const cfg_mod = @import("cfg.zig");
const ctrl = @import("ctrl.zig");
const decoder = @import("decoder.zig");
const stack_mod = @import("stack.zig");

const Allocator = std.mem.Allocator;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const StackValue = stack_mod.StackValue;
const BasicBlock = cfg_mod.BasicBlock;
const Opcode = decoder.Opcode;

pub fn Methods(comptime Self: type, comptime Err: type) type {
    return struct {
        const DecompileError = Err;

        pub const CondSim = struct {
            expr: *Expr,
            base_vals: []StackValue,
        };

        pub const BoolOpResult = struct {
            expr: *Expr,
            merge_block: u32,
        };

        fn popExprNoMatch(self: *Self, sim: *stack_mod.SimContext) DecompileError!?*Expr {
            return self.popExprMatch(sim) catch |err| switch (err) {
                error.PatternNoMatch => return null,
                else => return err,
            };
        }

        pub fn simulateTernaryBranch(
            self: *Self,
            block_id: u32,
            base_vals: []const StackValue,
        ) DecompileError!?*Expr {
            if (block_id >= self.cfg.blocks.len) return null;
            const block = &self.cfg.blocks[block_id];

            var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer sim.deinit();

            for (base_vals) |val| {
                try sim.stack.push(try sim.cloneStackValue(val));
            }

            for (block.instructions) |inst| {
                if (inst.isConditionalJump()) return null;
                if (inst.isUnconditionalJump()) break;
                if (Self.isStatementOpcode(inst.opcode)) return null;
                self.simOpt(&sim, inst) catch |err| switch (err) {
                    error.PatternNoMatch => return null,
                    else => return err,
                };
            }

            if (sim.stack.len() != base_vals.len + 1) return null;
            return (try popExprNoMatch(self, &sim)) orelse null;
        }

        pub fn simulateConditionExpr(
            self: *Self,
            block_id: u32,
            base_vals: []const StackValue,
        ) DecompileError!?*Expr {
            if (block_id >= self.cfg.blocks.len) return null;
            const block = &self.cfg.blocks[block_id];

            var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer sim.deinit();

            for (base_vals) |val| {
                try sim.stack.push(try sim.cloneStackValue(val));
            }

            for (block.instructions) |inst| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                if (Self.isStatementOpcode(inst.opcode)) return null;
                self.simOpt(&sim, inst) catch |err| switch (err) {
                    error.PatternNoMatch => return null,
                    else => return err,
                };
            }

            const expr = (try popExprNoMatch(self, &sim)) orelse return null;
            if (sim.stack.len() != base_vals.len) return null;
            return expr;
        }

        pub fn simulateValueExprSkip(
            self: *Self,
            block_id: u32,
            base_vals: []const StackValue,
            skip: usize,
        ) DecompileError!?*Expr {
            if (block_id >= self.cfg.blocks.len) return null;
            const block = &self.cfg.blocks[block_id];
            if (skip > block.instructions.len) return null;

            var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer sim.deinit();

            for (base_vals) |val| {
                try sim.stack.push(try sim.cloneStackValue(val));
            }

            for (block.instructions[skip..]) |inst| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                if (inst.isUnconditionalJump()) break;
                if (Self.isStatementOpcode(inst.opcode)) break;
                self.simOpt(&sim, inst) catch |err| switch (err) {
                    error.PatternNoMatch => return null,
                    else => return err,
                };
            }

            if (sim.stack.len() != base_vals.len + 1) return null;
            return (try popExprNoMatch(self, &sim)) orelse null;
        }

        pub fn simulateBoolOpCondExpr(
            self: *Self,
            block_id: u32,
            base_vals: []const StackValue,
            skip: usize,
            kind: ctrl.BoolOpKind,
        ) DecompileError!?*Expr {
            if (block_id >= self.cfg.blocks.len) return null;
            const block = &self.cfg.blocks[block_id];
            if (skip > block.instructions.len) return null;

            var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer sim.deinit();

            for (base_vals) |val| {
                try sim.stack.push(try sim.cloneStackValue(val));
            }

            for (block.instructions[skip..], 0..) |inst, rel_idx| {
                const idx = skip + rel_idx;
                if (kind == .pop_top) {
                    if (idx + 2 < block.instructions.len and
                        inst.opcode == .COPY and inst.arg == 1 and
                        block.instructions[idx + 1].opcode == .TO_BOOL and
                        ctrl.Analyzer.isConditionalJump(undefined, block.instructions[idx + 2].opcode))
                    {
                        break;
                    }
                }
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                if (Self.isStatementOpcode(inst.opcode)) return null;
                self.simOpt(&sim, inst) catch |err| switch (err) {
                    error.PatternNoMatch => return null,
                    else => return err,
                };
            }

            const expr = (try popExprNoMatch(self, &sim)) orelse return null;
            if (sim.stack.len() != base_vals.len) {
                if (sim.stack.len() == base_vals.len + 1 and expr.* == .compare and boolOpHasChainCompare(block, skip)) {
                    if (sim.stack.pop()) |extra| {
                        extra.deinit(sim.allocator, sim.stack_alloc);
                    }
                }
            }
            if (sim.stack.len() != base_vals.len) return null;
            return expr;
        }

        fn boolOpHasChainCompare(block: *const BasicBlock, skip: usize) bool {
            var has_dup = false;
            var has_rot = false;
            for (block.instructions[skip..]) |inst| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                if (inst.opcode == .DUP_TOP) has_dup = true;
                if (inst.opcode == .ROT_THREE or inst.opcode == .ROT_TWO) has_rot = true;
            }
            return has_dup and has_rot;
        }

        pub fn boolOpBlockSkip(
            self: *Self,
            block: *const BasicBlock,
            kind: ctrl.BoolOpKind,
        ) usize {
            _ = self;
            var skip: usize = 0;
            if (block.instructions.len > 0 and block.instructions[0].opcode == .NOT_TAKEN) {
                skip = 1;
            }
            if (kind == .pop_top and
                block.instructions.len > skip and
                block.instructions[skip].opcode == .POP_TOP)
            {
                skip += 1;
            }
            return skip;
        }

        fn blockHasLeadingStore(block: *const BasicBlock) bool {
            for (block.instructions) |inst| {
                if (inst.opcode == .NOT_TAKEN) continue;
                const name = inst.opcode.name();
                return std.mem.startsWith(u8, name, "STORE_");
            }
            return false;
        }

        pub fn initCondSim(
            self: *Self,
            block_id: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
        ) DecompileError!?CondSim {
            return initCondSimInner(self, block_id, stmts, stmts_allocator, false);
        }

        pub fn initCondSimWithStore(
            self: *Self,
            block_id: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
        ) DecompileError!?CondSim {
            return initCondSimInner(self, block_id, stmts, stmts_allocator, false);
        }

        pub fn initCondSimWithSkipStore(
            self: *Self,
            block_id: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
            skip_first_store: bool,
        ) DecompileError!?CondSim {
            return initCondSimInner(self, block_id, stmts, stmts_allocator, skip_first_store);
        }

        fn initCondSimInner(
            self: *Self,
            block_id: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
            skip_first_store: bool,
        ) DecompileError!?CondSim {
            if (block_id >= self.cfg.blocks.len) return null;
            const cond_block = &self.cfg.blocks[block_id];

            var cond_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer cond_sim.deinit();
            cond_sim.lenient = true;
            if (block_id < self.stack_in.len) {
                if (self.stack_in[block_id]) |entry| {
                    for (entry) |val| {
                        const cloned = try cond_sim.cloneStackValue(val);
                        try cond_sim.stack.push(cloned);
                    }
                }
            }
            if (cond_sim.stack.len() > 0) {
                var all_unknown = true;
                for (cond_sim.stack.items.items) |val| {
                    if (val != .unknown) {
                        all_unknown = false;
                        break;
                    }
                }
                if (all_unknown and self.needsPredecessorSeed(cond_block)) {
                    cond_sim.stack.reset();
                    try self.seedFromPredecessors(block_id, &cond_sim);
                }
            } else if (self.needsPredecessorSeed(cond_block)) {
                try self.seedFromPredecessors(block_id, &cond_sim);
            }

            var stop_idx: usize = cond_block.instructions.len;
            for (cond_block.instructions, 0..) |inst, i| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                    stop_idx = i;
                    break;
                }
            }
            if (stop_idx >= cond_block.instructions.len) return null;

            var partial = cond_block.*;
            partial.instructions = cond_block.instructions[0..stop_idx];
            if (skip_first_store) {
                try self.processBlockWithSimSkipStore(&partial, &cond_sim, stmts, stmts_allocator, true);
            } else {
                try self.processBlockWithSim(&partial, &cond_sim, stmts, stmts_allocator);
            }

            const expr = (try popExprNoMatch(self, &cond_sim)) orelse return null;
            const base_vals = try self.cloneStackValues(cond_sim.stack.items.items);
            return .{ .expr = expr, .base_vals = base_vals };
        }

        fn saveExpr(
            self: *Self,
            merge_block: u32,
            expr: *Expr,
            base_vals: []StackValue,
            base_owned: *bool,
        ) DecompileError!void {
            try self.setStackEntryWithExpr(merge_block, base_vals, expr, base_owned);
        }

        pub fn saveTernary(
            self: *Self,
            merge_block: u32,
            condition: *Expr,
            true_expr: *Expr,
            false_expr: *Expr,
            base_vals: []StackValue,
            base_owned: *bool,
        ) DecompileError!void {
            const a = self.arena.allocator();
            const if_expr = try a.create(Expr);
            if_expr.* = .{ .if_exp = .{
                .condition = condition,
                .body = true_expr,
                .else_body = false_expr,
            } };

            try saveExpr(self, merge_block, if_expr, base_vals, base_owned);
        }

        fn tryFoldTernaryBoolOp(
            self: *Self,
            merge_block: u32,
            if_expr: *Expr,
            base_vals: []StackValue,
            base_owned: *bool,
            limit: u32,
        ) DecompileError!?u32 {
            if (merge_block >= self.cfg.blocks.len) return null;
            const merge_blk = &self.cfg.blocks[merge_block];
            const term = merge_blk.terminator() orelse return null;
            const is_and = switch (term.opcode) {
                .JUMP_IF_FALSE_OR_POP => true,
                .JUMP_IF_TRUE_OR_POP => false,
                else => return null,
            };

            var real_inst: ?decoder.Instruction = null;
            for (merge_blk.instructions) |inst| {
                if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                if (real_inst != null) return null;
                real_inst = inst;
            }
            if (real_inst == null or real_inst.?.opcode != term.opcode) return null;

            var short_id: ?u32 = null;
            var second_id: ?u32 = null;
            for (merge_blk.successors) |edge| {
                switch (edge.edge_type) {
                    .conditional_true, .normal => {
                        if (is_and) {
                            second_id = edge.target;
                        } else {
                            short_id = edge.target;
                        }
                    },
                    .conditional_false => {
                        if (is_and) {
                            short_id = edge.target;
                        } else {
                            second_id = edge.target;
                        }
                    },
                    else => {},
                }
            }
            const short = short_id orelse return null;
            const second = second_id orelse return null;
            if (short >= limit or second >= limit) return null;

            const second_blk = &self.cfg.blocks[second];
            const second_merge = blk: {
                for (second_blk.successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    if (edge.edge_type == .normal) break :blk edge.target;
                }
                break :blk null;
            };
            if (second_merge == null or second_merge.? != short) return null;

            const skip = boolOpBlockSkip(self, second_blk, .or_pop);
            const second_expr = (try simulateValueExprSkip(self, second, base_vals, skip)) orelse return null;
            const bool_expr = try self.makeBoolPair(if_expr, second_expr, if (is_and) .and_ else .or_);
            try saveExpr(self, short, bool_expr, base_vals, base_owned);
            return short;
        }

        pub fn findTernaryLeaf(
            self: *Self,
            start: u32,
            limit: u32,
        ) DecompileError!?ctrl.TernaryPattern {
            var seen = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
            defer seen.deinit();

            var stack: std.ArrayListUnmanaged(u32) = .{};
            defer stack.deinit(self.allocator);

            try stack.append(self.allocator, start);
            while (stack.items.len > 0) {
                const cur = stack.items[stack.items.len - 1];
                stack.items.len -= 1;
                if (cur >= self.cfg.blocks.len) continue;
                if (cur >= limit) continue;
                if (seen.isSet(cur)) continue;
                seen.set(cur);

                if (self.analyzer.detectTernary(cur)) |pat| {
                    if (pat.true_block < limit and pat.false_block < limit and pat.merge_block < limit) {
                        if (pat.merge_block > start) return pat;
                    }
                }

                const blk = &self.cfg.blocks[cur];
                const term = blk.terminator() orelse continue;
                if (!ctrl.Analyzer.isConditionalJump(undefined, term.opcode)) continue;
                for (blk.successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    try stack.append(self.allocator, edge.target);
                }
            }
            return null;
        }

        pub fn tryDecompileTernaryTreeInto(
            self: *Self,
            block_id: u32,
            limit: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
        ) DecompileError!?u32 {
            const pattern = (try findTernaryLeaf(self, block_id, limit)) orelse return null;

            const stmts_len = stmts.items.len;
            const cond_res = (try initCondSim(self, block_id, stmts, stmts_allocator)) orelse {
                stmts.items.len = stmts_len;
                return null;
            };
            const base_vals = cond_res.base_vals;
            var base_owned = true;
            defer if (base_owned) Self.deinitStackValuesSlice(self.clone_sim.allocator, self.clone_sim.stack_alloc, self.allocator, base_vals);

            var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
            defer in_stack.deinit();

            var memo: std.AutoHashMapUnmanaged(u32, *Expr) = .{};
            defer memo.deinit(self.allocator);

            const condition = (try self.buildCondTree(
                block_id,
                block_id,
                cond_res.expr,
                pattern.true_block,
                pattern.false_block,
                base_vals,
                null,
                null,
                &in_stack,
                &memo,
            )) orelse {
                stmts.items.len = stmts_len;
                return null;
            };

            const true_expr = (try simulateTernaryBranch(self, pattern.true_block, base_vals)) orelse {
                stmts.items.len = stmts_len;
                return null;
            };
            const false_expr = (try simulateTernaryBranch(self, pattern.false_block, base_vals)) orelse {
                stmts.items.len = stmts_len;
                return null;
            };

            const a = self.arena.allocator();
            const if_expr = try a.create(Expr);
            if_expr.* = .{ .if_exp = .{
                .condition = condition,
                .body = true_expr,
                .else_body = false_expr,
            } };
            if (try tryFoldTernaryBoolOp(self, pattern.merge_block, if_expr, base_vals, &base_owned, limit)) |next_block| {
                return next_block;
            }
            try saveExpr(self, pattern.merge_block, if_expr, base_vals, &base_owned);
            return pattern.merge_block;
        }

        pub fn tryDecompileTernaryInto(
            self: *Self,
            block_id: u32,
            limit: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
        ) DecompileError!?u32 {
            return self.tryDecompileTernaryIntoWithSkip(block_id, limit, stmts, stmts_allocator, false);
        }

        pub fn tryDecompileTernaryIntoWithSkip(
            self: *Self,
            block_id: u32,
            limit: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
            skip_first_store: bool,
        ) DecompileError!?u32 {
            if (try self.analyzer.detectTernaryChain(block_id)) |chain| {
                defer self.allocator.free(chain.condition_blocks);
                if (chain.true_block >= limit or chain.false_block >= limit or chain.merge_block >= limit) {
                    return null;
                }
                if (chain.merge_block <= block_id) return null;

                var base_vals: []StackValue = &.{};
                var base_owned = false;
                var true_expr: *Expr = undefined;
                var false_expr: *Expr = undefined;

                var cond_list: std.ArrayListUnmanaged(*Expr) = .{};
                defer cond_list.deinit(self.allocator);

                defer {
                    if (base_owned) {
                        Self.deinitStackValuesSlice(self.clone_sim.allocator, self.clone_sim.stack_alloc, self.allocator, base_vals);
                    }
                }

                const stmts_len = stmts.items.len;
                const cond_res = (try initCondSimWithSkipStore(self, chain.condition_blocks[0], stmts, stmts_allocator, skip_first_store)) orelse {
                    stmts.items.len = stmts_len;
                    return null;
                };
                try cond_list.append(self.allocator, cond_res.expr);
                base_vals = cond_res.base_vals;
                base_owned = true;

                if (chain.condition_blocks.len > 1) {
                    for (chain.condition_blocks[1..]) |cond_id| {
                        const cond_opt = try simulateConditionExpr(self, cond_id, base_vals);
                        if (cond_opt == null) {
                            stmts.items.len = stmts_len;
                            return null;
                        }
                        try cond_list.append(self.allocator, cond_opt.?);
                    }
                }

                const condition = blk: {
                    if (cond_list.items.len == 1) break :blk cond_list.items[0];
                    const a = self.arena.allocator();
                    const values = try a.dupe(*Expr, cond_list.items);
                    const bool_expr = try a.create(Expr);
                    bool_expr.* = .{ .bool_op = .{
                        .op = if (chain.is_and) .and_ else .or_,
                        .values = values,
                    } };
                    break :blk bool_expr;
                };

                const true_opt = try simulateTernaryBranch(self, chain.true_block, base_vals);
                if (true_opt == null) {
                    stmts.items.len = stmts_len;
                    return null;
                }
                true_expr = true_opt.?;

                const false_opt = try simulateTernaryBranch(self, chain.false_block, base_vals);
                if (false_opt == null) {
                    stmts.items.len = stmts_len;
                    return null;
                }
                false_expr = false_opt.?;

                const a = self.arena.allocator();
                const if_expr = try a.create(Expr);
                if_expr.* = .{ .if_exp = .{
                    .condition = condition,
                    .body = true_expr,
                    .else_body = false_expr,
                } };
                if (try tryFoldTernaryBoolOp(self, chain.merge_block, if_expr, base_vals, &base_owned, limit)) |next_block| {
                    return next_block;
                }
                try saveExpr(self, chain.merge_block, if_expr, base_vals, &base_owned);
                return chain.merge_block;
            }

            if (try tryDecompileTernaryTreeInto(self, block_id, limit, stmts, stmts_allocator)) |next_block| {
                return next_block;
            }

            const pattern = self.analyzer.detectTernary(block_id) orelse return null;
            if (pattern.true_block >= limit or pattern.false_block >= limit or pattern.merge_block >= limit) {
                return null;
            }
            if (pattern.merge_block <= block_id) return null;

            var base_vals: []StackValue = &.{};
            var base_owned = false;
            var true_expr: *Expr = undefined;
            var false_expr: *Expr = undefined;

            defer {
                if (base_owned) {
                    Self.deinitStackValuesSlice(self.clone_sim.allocator, self.clone_sim.stack_alloc, self.allocator, base_vals);
                }
            }

            const stmts_len = stmts.items.len;
            const cond_res = (try initCondSimWithSkipStore(self, pattern.condition_block, stmts, stmts_allocator, skip_first_store)) orelse {
                stmts.items.len = stmts_len;
                return null;
            };
            const condition = cond_res.expr;
            base_vals = cond_res.base_vals;
            base_owned = true;

            const true_opt = try simulateTernaryBranch(self, pattern.true_block, base_vals);
            if (true_opt == null) {
                stmts.items.len = stmts_len;
                return null;
            }
            true_expr = true_opt.?;

            const false_opt = try simulateTernaryBranch(self, pattern.false_block, base_vals);
            if (false_opt == null) {
                stmts.items.len = stmts_len;
                return null;
            }
            false_expr = false_opt.?;

            const a = self.arena.allocator();
            const if_expr = try a.create(Expr);
            if_expr.* = .{ .if_exp = .{
                .condition = condition,
                .body = true_expr,
                .else_body = false_expr,
            } };
            if (try tryFoldTernaryBoolOp(self, pattern.merge_block, if_expr, base_vals, &base_owned, limit)) |next_block| {
                return next_block;
            }
            try saveExpr(self, pattern.merge_block, if_expr, base_vals, &base_owned);
            return pattern.merge_block;
        }

        pub fn tryDecompileAndOrInto(
            self: *Self,
            block_id: u32,
            limit: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
        ) DecompileError!?u32 {
            const pattern = self.analyzer.detectAndOr(block_id) orelse return null;
            if (pattern.true_block >= limit or pattern.false_block >= limit or pattern.merge_block >= limit) {
                return null;
            }
            if (pattern.merge_block <= block_id) return null;

            const stmts_len = stmts.items.len;
            const cond_opt = try initCondSim(self, pattern.condition_block, stmts, stmts_allocator);
            const cond_res = cond_opt orelse {
                stmts.items.len = stmts_len;
                return null;
            };
            const base_vals = cond_res.base_vals;
            var base_owned = true;
            defer if (base_owned) Self.deinitStackValuesSlice(self.clone_sim.allocator, self.clone_sim.stack_alloc, self.allocator, base_vals);

            const true_blk = &self.cfg.blocks[pattern.true_block];
            const false_blk = &self.cfg.blocks[pattern.false_block];
            const true_skip = boolOpBlockSkip(self, true_blk, .or_pop);
            const false_skip = boolOpBlockSkip(self, false_blk, .or_pop);

            const true_expr = (try simulateValueExprSkip(self, pattern.true_block, base_vals, true_skip)) orelse {
                stmts.items.len = stmts_len;
                return null;
            };
            var false_expr: *Expr = undefined;
            if (self.analyzer.detectBoolOp(pattern.false_block)) |bool_pat| {
                if (bool_pat.merge_block == pattern.merge_block) {
                    const first = (try simulateBoolOpCondExpr(self, pattern.false_block, base_vals, false_skip, bool_pat.kind)) orelse {
                        stmts.items.len = stmts_len;
                        return null;
                    };
                    const bool_res = try buildBoolOpExpr(self, first, bool_pat, base_vals);
                    false_expr = bool_res.expr;
                } else {
                    false_expr = (try simulateValueExprSkip(self, pattern.false_block, base_vals, false_skip)) orelse {
                        stmts.items.len = stmts_len;
                        return null;
                    };
                }
            } else {
                false_expr = (try simulateValueExprSkip(self, pattern.false_block, base_vals, false_skip)) orelse {
                    stmts.items.len = stmts_len;
                    return null;
                };
            }

            const and_expr = try self.makeBoolPair(cond_res.expr, true_expr, .and_);
            const or_expr = try self.makeBoolPair(and_expr, false_expr, .or_);

            const merge_block = &self.cfg.blocks[pattern.merge_block];
            if (merge_block.terminator()) |mt| {
                if (ctrl.Analyzer.isConditionalJump(undefined, mt.opcode)) {
                    try self.setStackEntryWithExpr(pattern.merge_block, base_vals, or_expr, &base_owned);
                    return pattern.merge_block;
                }
            }

            var merge_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer merge_sim.deinit();
            if (base_vals.len > 0) {
                for (base_vals) |val| {
                    const cloned = try merge_sim.cloneStackValue(val);
                    try merge_sim.stack.push(cloned);
                }
            }
            try merge_sim.stack.push(.{ .expr = or_expr });
            self.processBlockWithSim(merge_block, &merge_sim, stmts, stmts_allocator) catch |err| {
                switch (err) {
                    error.StackUnderflow, error.NotAnExpression, error.InvalidBlock => {
                        stmts.items.len = stmts_len;
                        return error.PatternNoMatch;
                    },
                    else => return err,
                }
            };

            return pattern.merge_block + 1;
        }

        pub fn tryDecompileBoolOpInto(
            self: *Self,
            block_id: u32,
            limit: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
        ) DecompileError!?u32 {
            return self.tryDecompileBoolOpIntoWithSkip(block_id, limit, stmts, stmts_allocator, false);
        }

        pub fn tryDecompileBoolOpIntoWithSkip(
            self: *Self,
            block_id: u32,
            limit: u32,
            stmts: *std.ArrayListUnmanaged(*Stmt),
            stmts_allocator: Allocator,
            skip_first_store_param: bool,
        ) DecompileError!?u32 {
            const pattern = self.analyzer.detectBoolOp(block_id) orelse return null;
            if (pattern.second_block >= limit or pattern.merge_block >= limit) {
                return null;
            }

            const cond_block = &self.cfg.blocks[pattern.condition_block];
            const jump_idx = blk: {
                var idx: ?usize = null;
                for (cond_block.instructions, 0..) |inst, i| {
                    if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                        idx = i;
                        break;
                    }
                }
                break :blk idx orelse return null;
            };
            var skip_first_store = skip_first_store_param;
            try self.processPartialBlock(cond_block, stmts, stmts_allocator, &skip_first_store, jump_idx);
            var cond_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer cond_sim.deinit();
            if (pattern.condition_block < self.stack_in.len) {
                if (self.stack_in[pattern.condition_block]) |entry| {
                    for (entry) |val| {
                        const cloned = try cond_sim.cloneStackValue(val);
                        try cond_sim.stack.push(cloned);
                    }
                }
            }
            if (cond_sim.stack.len() == 0 and self.needsPredecessorSeed(cond_block)) {
                try self.seedFromPredecessors(pattern.condition_block, &cond_sim);
            }

            if (pattern.kind == .pop_top) {
                // Simulate condition block up to COPY (before TO_BOOL)
                for (cond_block.instructions, 0..) |inst, i| {
                    // Stop before COPY, TO_BOOL, POP_JUMP sequence
                    if (i + 3 >= cond_block.instructions.len) break;
                    if (inst.opcode == .COPY and
                        cond_block.instructions[i + 1].opcode == .TO_BOOL and
                        ctrl.Analyzer.isConditionalJump(undefined, cond_block.instructions[i + 2].opcode))
                    {
                        break;
                    }
                    if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                    cond_sim.simulate(inst) catch |err| {
                        if (self.isSoftSimErr(err)) return error.PatternNoMatch;
                        return err;
                    };
                }
            } else {
                // Simulate condition block up to conditional jump
                for (cond_block.instructions) |inst| {
                    if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                    cond_sim.simulate(inst) catch |err| {
                        if (self.isSoftSimErr(err)) return error.PatternNoMatch;
                        return err;
                    };
                }
            }

            // First operand is on stack
            const first = cond_sim.stack.popExpr() catch |err| {
                if (self.isSoftSimErr(err)) return error.PatternNoMatch;
                return err;
            };

            const base_vals = try self.cloneStackValues(cond_sim.stack.items.items);
            var base_owned = true;
            defer if (base_owned) Self.deinitStackValuesSlice(self.clone_sim.allocator, self.clone_sim.stack_alloc, self.allocator, base_vals);

            // Build potentially nested BoolOp expression
            const bool_result = buildBoolOpExpr(self, first, pattern, base_vals) catch |err| {
                if (err == error.InvalidBlock or err == error.PatternNoMatch) return error.PatternNoMatch;
                return err;
            };
            const bool_expr = bool_result.expr;
            const final_merge = bool_result.merge_block;
            try self.markConsumed(pattern.condition_block);
            try self.markConsumed(pattern.second_block);

            // Process merge block with the bool expression on stack
            const merge_block = &self.cfg.blocks[final_merge];
            if (merge_block.terminator()) |mt| {
                if (ctrl.Analyzer.isConditionalJump(undefined, mt.opcode)) {
                    try self.setStackEntryWithExpr(final_merge, base_vals, bool_expr, &base_owned);
                    return final_merge;
                }
            }
            if (self.blockIsCleanupOnly(merge_block)) {
                var next: ?u32 = null;
                for (merge_block.successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    if (next != null) {
                        next = null;
                        break;
                    }
                    next = edge.target;
                }
                if (next) |next_block| {
                    try self.markConsumed(final_merge);
                    try self.setStackEntryWithExpr(next_block, base_vals, bool_expr, &base_owned);
                    return next_block;
                }
            }

            var merge_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer merge_sim.deinit();
            if (base_vals.len > 0) {
                for (base_vals) |val| {
                    const cloned = try merge_sim.cloneStackValue(val);
                    try merge_sim.stack.push(cloned);
                }
            }
            try merge_sim.stack.push(.{ .expr = bool_expr });
            self.processBlockWithSim(merge_block, &merge_sim, stmts, stmts_allocator) catch |err| {
                switch (err) {
                    error.StackUnderflow, error.NotAnExpression, error.InvalidBlock => return error.PatternNoMatch,
                    else => return err,
                }
            };
            try self.markConsumed(final_merge);
            return final_merge + 1;
        }

        fn boolOpIsAnd(op: Opcode) ?bool {
            return switch (op) {
                .POP_JUMP_IF_FALSE,
                .POP_JUMP_FORWARD_IF_FALSE,
                .POP_JUMP_BACKWARD_IF_FALSE,
                .JUMP_IF_FALSE_OR_POP,
                .JUMP_IF_FALSE,
                => true,
                .POP_JUMP_IF_TRUE,
                .POP_JUMP_FORWARD_IF_TRUE,
                .POP_JUMP_BACKWARD_IF_TRUE,
                .JUMP_IF_TRUE_OR_POP,
                .JUMP_IF_TRUE,
                => false,
                else => null,
            };
        }

        fn boolOpKind(op: Opcode) ?ctrl.BoolOpKind {
            return switch (op) {
                .POP_JUMP_IF_FALSE,
                .POP_JUMP_FORWARD_IF_FALSE,
                .POP_JUMP_BACKWARD_IF_FALSE,
                .POP_JUMP_IF_TRUE,
                .POP_JUMP_FORWARD_IF_TRUE,
                .POP_JUMP_BACKWARD_IF_TRUE,
                => .pop_top,
                .JUMP_IF_FALSE_OR_POP,
                .JUMP_IF_TRUE_OR_POP,
                .JUMP_IF_FALSE,
                .JUMP_IF_TRUE,
                => .or_pop,
                else => null,
            };
        }

        pub fn buildBoolOpExpr(
            self: *Self,
            first: *Expr,
            pattern: ctrl.BoolOpPattern,
            base_vals: []const StackValue,
        ) DecompileError!BoolOpResult {
            var values_list: std.ArrayListUnmanaged(*Expr) = .{};
            defer values_list.deinit(self.allocator);

            try values_list.append(self.allocator, first);

            var seen = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
            defer seen.deinit();

            var cur_block = pattern.second_block;
            const final_merge = pattern.merge_block;

            while (true) {
                if (cur_block >= self.cfg.blocks.len) return error.InvalidBlock;
                if (seen.isSet(cur_block)) return error.InvalidBlock;
                seen.set(cur_block);

                const blk = &self.cfg.blocks[cur_block];
                const skip = boolOpBlockSkip(self, blk, pattern.kind);

                if (try tryBuildChainCompareExpr(self, cur_block, base_vals)) |chain| {
                    try values_list.append(self.allocator, chain.expr);
                    cur_block = chain.merge_block;
                    if (cur_block == final_merge) break;
                    continue;
                }

                const term = blk.terminator();
                const is_cond = if (term) |t| ctrl.Analyzer.isConditionalJump(undefined, t.opcode) else false;
                if (!is_cond) {
                    const expr = (try simulateValueExprSkip(self, cur_block, base_vals, skip)) orelse {
                        return error.InvalidBlock;
                    };
                    try values_list.append(self.allocator, expr);
                    break;
                }

                const expr = (try simulateBoolOpCondExpr(self, cur_block, base_vals, skip, pattern.kind)) orelse {
                    return error.InvalidBlock;
                };
                const cur_is_and = boolOpIsAnd(term.?.opcode) orelse return error.InvalidBlock;
                const cur_kind = boolOpKind(term.?.opcode) orelse return error.InvalidBlock;
                if (cur_kind == pattern.kind and cur_is_and != pattern.is_and) {
                    const sub = self.analyzer.detectBoolOp(cur_block) orelse return error.InvalidBlock;
                    const sub_res = try buildBoolOpExpr(self, expr, sub, base_vals);
                    try values_list.append(self.allocator, sub_res.expr);
                    cur_block = sub_res.merge_block;
                    if (cur_block == final_merge) break;
                    continue;
                }

                var t_id: ?u32 = null;
                var f_id: ?u32 = null;
                for (blk.successors) |edge| {
                    if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                        t_id = edge.target;
                    } else if (edge.edge_type == .conditional_false) {
                        f_id = edge.target;
                    }
                }
                if (t_id == null or f_id == null) return error.InvalidBlock;

                const cont_id = if (pattern.is_and) t_id.? else f_id.?;
                const short_id = if (pattern.is_and) f_id.? else t_id.?;
                const reaches_cont = try self.condReach(short_id, cont_id, cont_id, final_merge);

                if (reaches_cont) {
                    var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
                    defer in_stack.deinit();

                    var memo: std.AutoHashMapUnmanaged(u32, *Expr) = .{};
                    defer memo.deinit(self.allocator);

                    const true_block = if (pattern.is_and) cont_id else final_merge;
                    const false_block = if (pattern.is_and) final_merge else cont_id;
                    const cond_expr = (try self.buildCondTree(
                        cur_block,
                        cur_block,
                        expr,
                        true_block,
                        false_block,
                        base_vals,
                        null,
                        pattern.kind,
                        &in_stack,
                        &memo,
                    )) orelse return error.InvalidBlock;
                    try values_list.append(self.allocator, cond_expr);
                    cur_block = cont_id;
                    continue;
                }

                try values_list.append(self.allocator, expr);
                cur_block = cont_id;
                if (cur_block == final_merge) break;
            }

            const a = self.arena.allocator();
            const values = try a.dupe(*Expr, values_list.items);
            const bool_expr = try a.create(Expr);
            bool_expr.* = .{ .bool_op = .{
                .op = if (pattern.is_and) .and_ else .or_,
                .values = values,
            } };

            return .{ .expr = bool_expr, .merge_block = final_merge };
        }

        fn tryBuildChainCompareExpr(
            self: *Self,
            block_id: u32,
            base_vals: []const StackValue,
        ) DecompileError!?struct { expr: *Expr, merge_block: u32 } {
            if (block_id >= self.cfg.blocks.len) return null;
            const block = &self.cfg.blocks[block_id];
            const term = block.terminator() orelse return null;
            if (term.opcode != .JUMP_IF_FALSE_OR_POP and term.opcode != .JUMP_IF_TRUE_OR_POP) return null;

            var has_dup = false;
            var has_rot = false;
            var cmp_idx: ?usize = null;
            for (block.instructions, 0..) |inst, i| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                if (inst.opcode == .DUP_TOP) has_dup = true;
                if (inst.opcode == .ROT_THREE or inst.opcode == .ROT_TWO) has_rot = true;
                if (inst.opcode == .COMPARE_OP and cmp_idx == null) cmp_idx = i;
            }
            if (!has_dup or !has_rot or cmp_idx == null) return null;

            var t_id: ?u32 = null;
            var f_id: ?u32 = null;
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                    t_id = edge.target;
                } else if (edge.edge_type == .conditional_false) {
                    f_id = edge.target;
                }
            }
            if (t_id == null or f_id == null) return null;

            const true_blk = &self.cfg.blocks[t_id.?];
            const false_blk = &self.cfg.blocks[f_id.?];

            const merge_true = singleNormalSucc(true_blk) orelse return null;
            const merge_false = singleNormalSucc(false_blk) orelse return null;
            if (merge_true != merge_false) return null;
            var merge_block = merge_true;

            var wrap_not = false;
            if (merge_block < self.cfg.blocks.len) {
                const mblk = &self.cfg.blocks[merge_block];
                var idx: usize = 0;
                if (mblk.instructions.len > 0 and mblk.instructions[0].opcode == .NOT_TAKEN) idx = 1;
                if (idx < mblk.instructions.len and mblk.instructions[idx].opcode == .UNARY_NOT) {
                    var only_not = true;
                    for (mblk.instructions[idx + 1 ..]) |inst| {
                        if (inst.opcode == .NOP) continue;
                        only_not = false;
                        break;
                    }
                    if (only_not) {
                        if (singleNormalSucc(mblk)) |next_id| {
                            wrap_not = true;
                            merge_block = next_id;
                        }
                    }
                }
            }

            var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer sim.deinit();
            for (base_vals) |val| {
                try sim.stack.push(try sim.cloneStackValue(val));
            }
            const stop_idx = cmp_idx.?;
            for (block.instructions[0 .. stop_idx + 1]) |inst| {
                self.simOpt(&sim, inst) catch |err| switch (err) {
                    error.PatternNoMatch => return null,
                    else => return err,
                };
            }
            const first_cmp = (try popExprNoMatch(self, &sim)) orelse return null;
            if (first_cmp.* != .compare or first_cmp.compare.ops.len != 1 or first_cmp.compare.comparators.len != 1) {
                return null;
            }
            const left = first_cmp.compare.left;
            const mid = first_cmp.compare.comparators[0];
            const op1 = first_cmp.compare.ops[0];

            var sim2 = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer sim2.deinit();
            for (base_vals) |val| {
                try sim2.stack.push(try sim2.cloneStackValue(val));
            }
            try sim2.stack.push(.{ .expr = mid });
            var cmp2_idx: ?usize = null;
            for (true_blk.instructions, 0..) |inst, i| {
                if (inst.opcode == .COMPARE_OP) {
                    cmp2_idx = i;
                    break;
                }
                self.simOpt(&sim2, inst) catch |err| switch (err) {
                    error.PatternNoMatch => return null,
                    else => return err,
                };
            }
            if (cmp2_idx == null) return null;
            self.simOpt(&sim2, true_blk.instructions[cmp2_idx.?]) catch |err| switch (err) {
                error.PatternNoMatch => return null,
                else => return err,
            };
            const second_cmp = (try popExprNoMatch(self, &sim2)) orelse return null;
            if (second_cmp.* != .compare or second_cmp.compare.ops.len != 1 or second_cmp.compare.comparators.len != 1) {
                return null;
            }
            const right = second_cmp.compare.comparators[0];
            const op2 = second_cmp.compare.ops[0];

            const a = self.arena.allocator();
            const ops = try a.alloc(ast.CmpOp, 2);
            ops[0] = op1;
            ops[1] = op2;
            const comps = try a.alloc(*Expr, 2);
            comps[0] = mid;
            comps[1] = right;
            var expr = try ast.makeCompare(a, left, ops, comps);
            if (wrap_not) {
                expr = try ast.makeUnaryOp(a, .not_, expr);
            }

            return .{ .expr = expr, .merge_block = merge_block };
        }

        fn singleNormalSucc(block: *const BasicBlock) ?u32 {
            var next: ?u32 = null;
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (next != null) return null;
                next = edge.target;
            }
            return next;
        }
    };
}
