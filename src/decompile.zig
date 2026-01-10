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

/// Error context for debugging.
pub const ErrorContext = struct {
    code_name: []const u8,
    block_id: u32,
    offset: u32,
    opcode: []const u8,
};

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
    /// Next block after chained comparison (set by tryDecompileChainedComparison).
    chained_cmp_next_block: ?u32 = null,
    /// Pending ternary expression to be consumed by next STORE instruction.
    pending_ternary_expr: ?*Expr = null,
    /// Accumulated print items for Python 2.x PRINT_ITEM/PRINT_NEWLINE.
    print_items: std.ArrayList(*Expr),
    /// Print destination for PRINT_ITEM_TO.
    print_dest: ?*Expr = null,
    /// Error context for debugging.
    last_error_ctx: ?ErrorContext = null,

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
            .print_items = .{},
        };
    }

    pub fn deinit(self: *Decompiler) void {
        for (self.nested_decompilers.items) |nested| {
            nested.deinit();
            self.allocator.destroy(nested);
        }
        self.nested_decompilers.deinit(self.allocator);
        self.print_items.deinit(self.allocator);
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

    /// Try to emit a statement for the given opcode from the current stack state.
    /// Returns the statement if one was emitted, null otherwise.
    fn tryEmitStatement(self: *Decompiler, inst: decoder.Instruction, sim: *SimContext) DecompileError!?*Stmt {
        switch (inst.opcode) {
            .STORE_NAME, .STORE_FAST, .STORE_GLOBAL => {
                const name = switch (inst.opcode) {
                    .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                    .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                    else => "<unknown>",
                };
                const value = sim.stack.pop() orelse return error.StackUnderflow;
                errdefer value.deinit(self.allocator);
                return try self.handleStoreValue(name, value);
            },
            .POP_TOP => {
                const val = sim.stack.pop() orelse return error.StackUnderflow;
                switch (val) {
                    .expr => |e| {
                        return try self.makeExprStmt(e);
                    },
                    else => {
                        val.deinit(self.allocator);
                        return null;
                    },
                }
            },
            else => {
                // For other statement opcodes, simulate and don't emit
                try sim.simulate(inst);
                return null;
            },
        }
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
        return self.processBlockWithSimAndSkip(block, sim, stmts, 0);
    }

    fn processBlockWithSimAndSkip(
        self: *Decompiler,
        block: *const BasicBlock,
        sim: *SimContext,
        stmts: *std.ArrayList(*Stmt),
        skip_first: usize,
    ) DecompileError!void {
        // Check for pending ternary expression from tryDecompileTernaryInto
        if (self.pending_ternary_expr) |expr| {
            try sim.stack.push(.{ .expr = expr });
            self.pending_ternary_expr = null;
        }

        const instructions = block.instructions[skip_first..];
        var i: usize = 0;
        while (i < instructions.len) : (i += 1) {
            const inst = instructions[i];
            errdefer self.last_error_ctx = .{
                .code_name = self.code.name,
                .block_id = block.id,
                .offset = inst.offset,
                .opcode = inst.opcode.name(),
            };
            switch (inst.opcode) {
                .UNPACK_SEQUENCE => {
                    // Look ahead for N STORE_* instructions to generate unpacking assignment
                    const count = inst.arg;
                    const seq_expr = try sim.stack.popExpr();
                    const arena = self.arena.allocator();

                    // Collect target names from following STORE_* instructions
                    var targets = try std.ArrayList([]const u8).initCapacity(arena, count);

                    var j: usize = 0;
                    while (j < count and i + 1 + j < instructions.len) : (j += 1) {
                        const store_inst = instructions[i + 1 + j];
                        const name: ?[]const u8 = switch (store_inst.opcode) {
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(store_inst.arg),
                            .STORE_FAST => sim.getLocal(store_inst.arg),
                            else => null,
                        };
                        if (name) |n| {
                            try targets.append(arena, n);
                        } else {
                            break;
                        }
                    }

                    if (targets.items.len == count) {
                        // Generate unpacking assignment: a, b, c = expr
                        const stmt = try self.makeUnpackAssign(targets.items, seq_expr);
                        try stmts.append(self.allocator, stmt);
                        i += count; // Skip the STORE instructions
                    } else {
                        // Fallback: push unknown for each element
                        var k: u32 = 0;
                        while (k < count) : (k += 1) {
                            try sim.stack.push(.unknown);
                        }
                    }
                },
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
                    const val = sim.stack.pop() orelse return error.StackUnderflow;
                    switch (val) {
                        .expr => |e| {
                            const stmt = try self.makeExprStmt(e);
                            try stmts.append(self.allocator, stmt);
                        },
                        else => {
                            // Discard non-expression values (e.g., intermediate stack values)
                            val.deinit(self.allocator);
                        },
                    }
                },
                .END_FOR, .POP_ITER => {
                    // Loop cleanup opcodes - skip in non-loop context
                },
                .PRINT_ITEM => {
                    // Collect print item - will be emitted with PRINT_NEWLINE
                    const val = try sim.stack.popExpr();
                    try self.print_items.append(self.allocator, val);
                },
                .PRINT_NEWLINE => {
                    // Emit print statement with collected items
                    const stmt = try self.makePrintStmt(null, true);
                    try stmts.append(self.allocator, stmt);
                },
                .PRINT_ITEM_TO => {
                    // Stack: [..., file, value, file] after ROT_TWO
                    // Pop file (TOS), then value (TOS1)
                    const file = try sim.stack.popExpr();
                    const val = try sim.stack.popExpr();
                    // Save file for PRINT_NEWLINE_TO (arena-allocated, no manual free)
                    if (self.print_dest == null) {
                        self.print_dest = file;
                    }
                    // Duplicate file refs are fine - arena will free all
                    try self.print_items.append(self.allocator, val);
                },
                .PRINT_NEWLINE_TO => {
                    // Pop file (it's still on stack after last PRINT_ITEM_TO or just loaded)
                    const file = try sim.stack.popExpr();
                    // Use saved dest if available (from PRINT_ITEM_TO), otherwise use popped file
                    const dest = self.print_dest orelse file;
                    self.print_dest = null;
                    const stmt = try self.makePrintStmt(dest, true);
                    try stmts.append(self.allocator, stmt);
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

    fn simulateConditionExpr(
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
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (isStatementOpcode(inst.opcode)) return null;
            try sim.simulate(inst);
        }

        const expr = sim.stack.popExpr() catch return null;
        if (sim.stack.len() != base_vals.len) return null;
        return expr;
    }

    fn tryDecompileTernaryInto(
        self: *Decompiler,
        block_id: u32,
        limit: u32,
        stmts: *std.ArrayList(*Stmt),
    ) DecompileError!?u32 {
        if (try self.analyzer.detectTernaryChain(block_id)) |chain| {
            defer self.allocator.free(chain.condition_blocks);
            if (chain.true_block >= limit or chain.false_block >= limit or chain.merge_block >= limit) {
                return null;
            }
            if (chain.merge_block <= block_id) return null;

            var condition: *Expr = undefined;
            var base_vals: []StackValue = &.{};
            var base_owned = false;
            var true_expr: *Expr = undefined;
            var false_expr: *Expr = undefined;
            var if_expr: *Expr = undefined;

            var cond_list: std.ArrayListUnmanaged(*Expr) = .{};
            defer cond_list.deinit(self.allocator);

            // Note: expressions are arena-allocated, so no explicit cleanup needed
            defer {
                if (base_owned) {
                    deinitStackValuesSlice(self.allocator, base_vals);
                }
            }

            const cond_block = &self.cfg.blocks[chain.condition_blocks[0]];
            var cond_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
            defer cond_sim.deinit();

            // Check for pending ternary expression from a previous ternary
            if (self.pending_ternary_expr) |expr| {
                try cond_sim.stack.push(.{ .expr = expr });
                self.pending_ternary_expr = null;
            }

            // Process condition block, emitting any leading statements
            for (cond_block.instructions) |inst| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                if (isStatementOpcode(inst.opcode)) {
                    if (try self.tryEmitStatement(inst, &cond_sim)) |stmt| {
                        try stmts.append(self.allocator, stmt);
                    }
                } else {
                    try cond_sim.simulate(inst);
                }
            }

            const first_cond = cond_sim.stack.popExpr() catch return null;
            try cond_list.append(self.allocator, first_cond);

            base_vals = try self.cloneStackValues(&cond_sim, cond_sim.stack.items.items);
            base_owned = true;

            if (chain.condition_blocks.len > 1) {
                for (chain.condition_blocks[1..]) |cond_id| {
                    const cond_opt = try self.simulateConditionExpr(cond_id, base_vals);
                    if (cond_opt == null) return null;
                    try cond_list.append(self.allocator, cond_opt.?);
                }
            }

            if (cond_list.items.len == 1) {
                condition = cond_list.items[0];
            } else {
                const a = self.arena.allocator();
                const values = try a.dupe(*Expr, cond_list.items);
                const bool_expr = try a.create(Expr);
                bool_expr.* = .{ .bool_op = .{
                    .op = if (chain.is_and) .and_ else .or_,
                    .values = values,
                } };
                condition = bool_expr;
            }

            const true_opt = try self.simulateTernaryBranch(chain.true_block, base_vals);
            if (true_opt == null) return null;
            true_expr = true_opt.?;

            const false_opt = try self.simulateTernaryBranch(chain.false_block, base_vals);
            if (false_opt == null) return null;
            false_expr = false_opt.?;

            const a = self.arena.allocator();
            if_expr = try a.create(Expr);
            if_expr.* = .{ .if_exp = .{
                .condition = condition,
                .body = true_expr,
                .else_body = false_expr,
            } };

            // Don't process the merge block here - just save the ternary result
            // The main loop will process the merge block and consume this expression
            self.pending_ternary_expr = if_expr;

            // Free base_vals since we're not using them
            base_owned = false;
            deinitStackValuesSlice(self.allocator, base_vals);

            return chain.merge_block;
        }

        const pattern = self.analyzer.detectTernary(block_id) orelse return null;
        if (pattern.true_block >= limit or pattern.false_block >= limit or pattern.merge_block >= limit) {
            return null;
        }
        if (pattern.merge_block <= block_id) return null;

        var condition: *Expr = undefined;
        var base_vals: []StackValue = &.{};
        var base_owned = false;
        var true_expr: *Expr = undefined;
        var false_expr: *Expr = undefined;
        var if_expr: *Expr = undefined;

        // Note: expressions are arena-allocated, so no explicit cleanup needed
        defer {
            if (base_owned) {
                deinitStackValuesSlice(self.allocator, base_vals);
            }
        }

        const cond_block = &self.cfg.blocks[pattern.condition_block];
        var cond_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer cond_sim.deinit();

        // Check for pending ternary expression from a previous ternary
        if (self.pending_ternary_expr) |expr| {
            try cond_sim.stack.push(.{ .expr = expr });
            self.pending_ternary_expr = null;
        }

        // Process condition block, emitting any leading statements
        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (isStatementOpcode(inst.opcode)) {
                if (try self.tryEmitStatement(inst, &cond_sim)) |stmt| {
                    try stmts.append(self.allocator, stmt);
                }
            } else {
                try cond_sim.simulate(inst);
            }
        }

        condition = cond_sim.stack.popExpr() catch return null;

        base_vals = try self.cloneStackValues(&cond_sim, cond_sim.stack.items.items);
        base_owned = true;

        const true_opt = try self.simulateTernaryBranch(pattern.true_block, base_vals);
        if (true_opt == null) return null;
        true_expr = true_opt.?;

        const false_opt = try self.simulateTernaryBranch(pattern.false_block, base_vals);
        if (false_opt == null) return null;
        false_expr = false_opt.?;

        const a = self.arena.allocator();
        if_expr = try a.create(Expr);
        if_expr.* = .{ .if_exp = .{
            .condition = condition,
            .body = true_expr,
            .else_body = false_expr,
        } };

        // Don't process the merge block here - just save the ternary result
        // The main loop will process the merge block and consume this expression
        self.pending_ternary_expr = if_expr;

        // Free base_vals since we're not using them
        base_owned = false;
        deinitStackValuesSlice(self.allocator, base_vals);

        return pattern.merge_block;
    }

    /// Try to decompile a short-circuit boolean expression (x and y, x or y).
    fn tryDecompileBoolOpInto(
        self: *Decompiler,
        block_id: u32,
        limit: u32,
        stmts: *std.ArrayList(*Stmt),
    ) DecompileError!?u32 {
        const pattern = self.analyzer.detectBoolOp(block_id) orelse return null;
        if (pattern.second_block >= limit or pattern.merge_block >= limit) {
            return null;
        }

        const cond_block = &self.cfg.blocks[pattern.condition_block];
        var cond_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer cond_sim.deinit();

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
            try cond_sim.simulate(inst);
        }

        // First operand is on stack
        const first = cond_sim.stack.popExpr() catch return null;
        errdefer {
            first.deinit(self.allocator);
            self.allocator.destroy(first);
        }

        // Build potentially nested BoolOp expression
        const bool_result = try self.buildBoolOpExpr(first, pattern);
        const bool_expr = bool_result.expr;
        const final_merge = bool_result.merge_block;

        // Process merge block with the bool expression on stack
        var merge_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer merge_sim.deinit();
        try merge_sim.stack.push(.{ .expr = bool_expr });

        const merge_block = &self.cfg.blocks[final_merge];
        try self.processBlockWithSim(merge_block, &merge_sim, stmts);

        return final_merge + 1;
    }

    const BoolOpResult = struct {
        expr: *Expr,
        merge_block: u32,
    };

    /// Build a BoolOp expression, handling nested chains (x and y and z).
    fn buildBoolOpExpr(self: *Decompiler, first: *Expr, pattern: ctrl.BoolOpPattern) DecompileError!BoolOpResult {
        const sec_block = &self.cfg.blocks[pattern.second_block];
        var sec_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sec_sim.deinit();

        var skip: usize = 0;
        if (sec_block.instructions.len > 0 and sec_block.instructions[0].opcode == .NOT_TAKEN) {
            skip = 1;
        }
        if (sec_block.instructions.len > skip and sec_block.instructions[skip].opcode == .POP_TOP) {
            skip += 1;
        }

        // Simulate up to COPY or end
        for (sec_block.instructions[skip..], 0..) |inst, i| {
            const actual_idx = skip + i;
            // Stop before COPY, TO_BOOL, POP_JUMP sequence (nested boolop)
            if (actual_idx + 3 <= sec_block.instructions.len) {
                if (inst.opcode == .COPY and inst.arg == 1) {
                    if (sec_block.instructions[actual_idx + 1].opcode == .TO_BOOL and
                        ctrl.Analyzer.isConditionalJump(undefined, sec_block.instructions[actual_idx + 2].opcode))
                    {
                        break;
                    }
                }
            }
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (isStatementOpcode(inst.opcode)) break;
            try sec_sim.simulate(inst);
        }

        const second = sec_sim.stack.popExpr() catch return error.StackUnderflow;

        // Check if second_block has a nested BoolOp pattern
        const nested_pattern = self.analyzer.detectBoolOp(pattern.second_block);
        var final_merge = pattern.merge_block;
        var values_list: std.ArrayListUnmanaged(*Expr) = .{};

        try values_list.append(self.allocator, first);
        try values_list.append(self.allocator, second);

        if (nested_pattern) |nested| {
            // Same operator type - flatten the chain
            if (nested.is_and == pattern.is_and) {
                // Recursively build the rest of the chain
                const nested_result = try self.buildBoolOpExpr(second, nested);
                // Replace second with the nested expression's operands
                _ = values_list.pop();
                const expected_op: ast.BoolOp = if (pattern.is_and) .and_ else .or_;
                if (nested_result.expr.* == .bool_op and nested_result.expr.bool_op.op == expected_op) {
                    // Flatten: add all operands from nested
                    for (nested_result.expr.bool_op.values) |v| {
                        try values_list.append(self.allocator, v);
                    }
                } else {
                    try values_list.append(self.allocator, nested_result.expr);
                }
                final_merge = nested_result.merge_block;
            }
        }
        defer values_list.deinit(self.allocator);

        const a = self.arena.allocator();
        const values = try a.dupe(*Expr, values_list.items);

        const bool_expr = try a.create(Expr);
        bool_expr.* = .{ .bool_op = .{
            .op = if (pattern.is_and) .and_ else .or_,
            .values = values,
        } };

        return .{ .expr = bool_expr, .merge_block = final_merge };
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
            // Try BoolOp pattern first (x and y, x or y)
            if (try self.tryDecompileBoolOpInto(
                block_idx,
                @intCast(self.cfg.blocks.len),
                &self.statements,
            )) |next_block| {
                block_idx = next_block;
                continue;
            }
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
                    // Skip all processed blocks - use chained comparison override if set
                    if (self.chained_cmp_next_block) |chain_next| {
                        block_idx = chain_next;
                        self.chained_cmp_next_block = null;
                    } else {
                        block_idx = try self.findIfChainEnd(p);
                    }
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
                .match_stmt => |p| {
                    const result = try self.decompileMatch(p);
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
        return self.decompileBlockRangeWithStack(start_block, end_block, &.{});
    }

    /// Decompile a range of blocks with initial stack values.
    fn decompileBlockRangeWithStack(
        self: *Decompiler,
        start_block: u32,
        end_block: ?u32,
        init_stack: []const StackValue,
    ) DecompileError![]const *Stmt {
        return self.decompileBlockRangeWithStackAndSkip(start_block, end_block, init_stack, 0);
    }

    /// Decompile a range of blocks, skipping first N instructions of the first block.
    fn decompileBlockRangeWithStackAndSkip(
        self: *Decompiler,
        start_block: u32,
        end_block: ?u32,
        init_stack: []const StackValue,
        skip_first: usize,
    ) DecompileError![]const *Stmt {
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
            // First block gets the initial stack and skip
            if (block_idx == start_block) {
                try self.decompileBlockIntoWithStackAndSkip(block_idx, &stmts, init_stack, skip_first);
            } else {
                try self.decompileBlockInto(block_idx, &stmts);
            }
            block_idx += 1;
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    /// Decompile a single block's statements into the provided list.
    fn decompileBlockInto(self: *Decompiler, block_id: u32, stmts: *std.ArrayList(*Stmt)) DecompileError!void {
        return self.decompileBlockIntoWithStack(block_id, stmts, &.{});
    }

    /// Decompile a single block with initial stack values.
    fn decompileBlockIntoWithStack(
        self: *Decompiler,
        block_id: u32,
        stmts: *std.ArrayList(*Stmt),
        init_stack: []const StackValue,
    ) DecompileError!void {
        return self.decompileBlockIntoWithStackAndSkip(block_id, stmts, init_stack, 0);
    }

    /// Decompile a single block, optionally skipping first N instructions.
    fn decompileBlockIntoWithStackAndSkip(
        self: *Decompiler,
        block_id: u32,
        stmts: *std.ArrayList(*Stmt),
        init_stack: []const StackValue,
        skip_first: usize,
    ) DecompileError!void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        // Initialize stack with provided values
        if (init_stack.len > 0) {
            for (init_stack) |val| {
                const cloned = try sim.cloneStackValue(val);
                try sim.stack.push(cloned);
            }
        }

        try self.processBlockWithSimAndSkip(block, &sim, stmts, skip_first);
    }

    const ChainResult = struct {
        stmt: *Stmt,
        next_block: u32,
    };

    /// Try to decompile a chained comparison (e.g., a < b < c < d).
    /// Returns null if this is not a chained comparison.
    fn tryDecompileChainedComparison(
        self: *Decompiler,
        pattern: ctrl.IfPattern,
        first_cmp: *Expr,
        sim: *SimContext,
    ) DecompileError!?ChainResult {
        // Pattern: condition is a Compare, stack has values, then-block does POP_TOP + LOAD + COMPARE
        if (first_cmp.* != .compare) return null;
        if (sim.stack.len() == 0) return null;
        if (pattern.then_block >= self.cfg.blocks.len) return null;

        // Build the chain recursively
        var ops_list: std.ArrayListUnmanaged(ast.CmpOp) = .{};
        var comparators_list: std.ArrayListUnmanaged(*Expr) = .{};

        // Start with the first comparison's data
        try ops_list.append(self.allocator, first_cmp.compare.ops[0]);
        try comparators_list.append(self.allocator, first_cmp.compare.comparators[0]);

        const left = first_cmp.compare.left;
        var current_block_id = pattern.then_block;
        var current_mid = try sim.stack.popExpr();

        // Iterate through the chain
        while (current_block_id < self.cfg.blocks.len) {
            const blk = &self.cfg.blocks[current_block_id];
            if (blk.instructions.len < 3) break;

            // Check for POP_TOP pattern
            var idx: usize = 0;
            if (blk.instructions[0].opcode == .NOT_TAKEN) {
                if (blk.instructions.len < 4) break;
                idx = 1;
            }
            if (blk.instructions[idx].opcode != .POP_TOP) break;

            // Find COMPARE_OP - scan forward from POP_TOP
            var cmp_idx: usize = idx + 1;
            while (cmp_idx < blk.instructions.len) {
                if (blk.instructions[cmp_idx].opcode == .COMPARE_OP) break;
                cmp_idx += 1;
            }
            if (cmp_idx >= blk.instructions.len) break;

            // Determine start of simulation (after POP_TOP)
            const sim_start = idx + 1;

            // Simulate to get the comparison
            var then_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
            defer then_sim.deinit();
            try then_sim.stack.push(.{ .expr = current_mid });

            // Simulate instructions from after POP_TOP to compare (inclusive)
            for (blk.instructions[sim_start .. cmp_idx + 1]) |inst| {
                try then_sim.simulate(inst);
            }

            const cmp_expr = then_sim.stack.popExpr() catch break;
            if (cmp_expr.* != .compare) {
                cmp_expr.deinit(self.allocator);
                self.allocator.destroy(cmp_expr);
                break;
            }

            // Add to chain
            try ops_list.append(self.allocator, cmp_expr.compare.ops[0]);
            try comparators_list.append(self.allocator, cmp_expr.compare.comparators[0]);

            // Check if there's another link (COPY, TO_BOOL, POP_JUMP after COMPARE)
            if (cmp_idx + 3 < blk.instructions.len and
                blk.instructions[cmp_idx + 1].opcode == .COPY and
                blk.instructions[cmp_idx + 2].opcode == .TO_BOOL and
                ctrl.Analyzer.isConditionalJump(undefined, blk.instructions[cmp_idx + 3].opcode))
            {
                // More chain - get the next middle value from stack
                current_mid = then_sim.stack.popExpr() catch break;
                // Next block is the fallthrough
                var found_next = false;
                for (blk.successors) |edge| {
                    if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                        current_block_id = edge.target;
                        found_next = true;
                        break;
                    }
                }
                if (!found_next) break;
                continue;
            } else {
                // End of chain - check for RETURN_VALUE
                const has_return = cmp_idx + 1 < blk.instructions.len and
                    blk.instructions[cmp_idx + 1].opcode == .RETURN_VALUE;

                const a = self.arena.allocator();
                const ops = try a.dupe(ast.CmpOp, ops_list.items);
                const comparators = try a.dupe(*Expr, comparators_list.items);
                ops_list.deinit(self.allocator);
                comparators_list.deinit(self.allocator);

                const chain_expr = try a.create(Expr);
                chain_expr.* = .{ .compare = .{
                    .left = left,
                    .ops = ops,
                    .comparators = comparators,
                } };

                const stmt = try a.create(Stmt);
                if (has_return) {
                    stmt.* = .{ .return_stmt = .{ .value = chain_expr } };
                } else {
                    stmt.* = .{ .expr_stmt = .{ .value = chain_expr } };
                }
                // Skip to after the short-circuit block (which is else_block or merge_block)
                const short_circuit_block = pattern.else_block orelse pattern.merge_block orelse current_block_id;
                const next_block = @max(current_block_id + 1, short_circuit_block + 1);
                return .{ .stmt = stmt, .next_block = next_block };
            }
        }

        // Cleanup on failure
        ops_list.deinit(self.allocator);
        comparators_list.deinit(self.allocator);
        return null;
    }

    fn isLoadOpcode(op: Opcode) bool {
        return switch (op) {
            .LOAD_NAME, .LOAD_FAST, .LOAD_FAST_BORROW, .LOAD_GLOBAL, .SWAP, .COPY => true,
            else => false,
        };
    }

    /// Decompile an if statement pattern.
    fn decompileIf(self: *Decompiler, pattern: ctrl.IfPattern) DecompileError!?*Stmt {
        return self.decompileIfWithSkip(pattern, 0);
    }

    /// Decompile an if statement pattern, skipping first N instructions of condition block.
    fn decompileIfWithSkip(self: *Decompiler, pattern: ctrl.IfPattern, skip_cond: usize) DecompileError!?*Stmt {
        const cond_block = &self.cfg.blocks[pattern.condition_block];

        // Get the condition expression from the last instruction before the jump
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        // Check if terminator is Python 3.0 style JUMP_IF_FALSE/TRUE
        // These don't pop the condition, so branches start with POP_TOP
        const term = cond_block.terminator();
        const legacy_cond = if (term) |t| t.opcode == .JUMP_IF_FALSE or t.opcode == .JUMP_IF_TRUE else false;

        // Simulate up to but not including the conditional jump, skipping first N instructions
        for (cond_block.instructions[skip_cond..]) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            try sim.simulate(inst);
        }

        const condition = try sim.stack.popExpr();

        // Check for chained comparison pattern (Python 3.14+)
        if (try self.tryDecompileChainedComparison(pattern, condition, &sim)) |chain_result| {
            // condition's parts have been transferred to chain_result.stmt, don't deinit
            self.chained_cmp_next_block = chain_result.next_block;
            return chain_result.stmt;
        }
        self.chained_cmp_next_block = null;

        // Save remaining stack values to transfer to branches
        const base_vals = try self.allocator.alloc(StackValue, sim.stack.len());
        var saved: usize = 0;
        errdefer {
            for (base_vals[0..saved]) |val| {
                val.deinit(self.allocator);
            }
            self.allocator.free(base_vals);
        }
        for (0..sim.stack.len()) |i| {
            const val = sim.stack.items.items[i];
            base_vals[i] = try sim.cloneStackValue(val);
            saved += 1;
        }

        // For JUMP_IF_FALSE/TRUE (Python 3.0), skip the leading POP_TOP in each branch
        // that was used to clean up the condition left on stack
        const skip: usize = if (legacy_cond) 1 else 0;

        // Decompile the then body with inherited stack
        const then_end = pattern.else_block orelse pattern.merge_block;
        const then_body_tmp = try self.decompileBlockRangeWithStackAndSkip(pattern.then_block, then_end, base_vals, skip);
        defer self.allocator.free(then_body_tmp);
        const a = self.arena.allocator();
        const then_body = try a.dupe(*Stmt, then_body_tmp);

        // Decompile the else body
        const else_body = if (pattern.else_block) |else_id| blk: {
            // Check if else is an elif
            if (pattern.is_elif) {
                // Elif needs to start with fresh stack
                for (base_vals) |val| val.deinit(self.allocator);
                self.allocator.free(base_vals);

                // The else block is another if statement - recurse
                // For legacy conditionals, elif block starts with POP_TOP to clean up previous condition
                const else_pattern = try self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    const elif_stmt = try self.decompileIfWithSkip(else_pattern.if_stmt, skip);
                    if (elif_stmt) |s| {
                        const body = try a.alloc(*Stmt, 1);
                        body[0] = s;
                        break :blk body;
                    }
                }
                break :blk &[_]*Stmt{};
            }
            // Regular else with inherited stack
            defer {
                for (base_vals) |val| val.deinit(self.allocator);
                self.allocator.free(base_vals);
            }
            const else_body_tmp = try self.decompileBlockRangeWithStackAndSkip(else_id, pattern.merge_block, base_vals, skip);
            defer self.allocator.free(else_body_tmp);
            break :blk try a.dupe(*Stmt, else_body_tmp);
        } else blk: {
            // No else block - clean up base_vals
            for (base_vals) |val| val.deinit(self.allocator);
            self.allocator.free(base_vals);
            break :blk &[_]*Stmt{};
        };

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
            if (inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH or inst.opcode == .LOAD_SPECIAL) {
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

    fn decompileMatch(self: *Decompiler, pattern: ctrl.MatchPattern) DecompileError!PatternResult {
        // Get subject from subject block - simulate only until MATCH_* or COPY
        const subj_block = &self.cfg.blocks[pattern.subject_block];
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (subj_block.instructions) |inst| {
            // Stop before MATCH_* opcodes - subject is on stack now
            if (inst.opcode == .MATCH_SEQUENCE or inst.opcode == .MATCH_MAPPING or
                inst.opcode == .MATCH_CLASS or inst.opcode == .COPY)
            {
                break;
            }
            sim.simulate(inst) catch {};
        }

        const subject = sim.stack.popExpr() catch {
            // Fallback: create unknown expression
            const expr = try self.allocator.create(Expr);
            expr.* = .{ .name = .{ .id = "<unknown>", .ctx = .load } };
            return .{ .stmt = null, .next_block = pattern.exit_block orelse pattern.subject_block + 1 };
        };

        // Decompile each case
        var cases: std.ArrayList(ast.MatchCase) = .{};
        errdefer cases.deinit(self.allocator);

        for (pattern.case_blocks) |case_block_id| {
            const case = try self.decompileMatchCase(case_block_id);
            try cases.append(self.allocator, case);
        }

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{
            .match_stmt = .{
                .subject = subject,
                .cases = try cases.toOwnedSlice(self.allocator),
            },
        };

        return .{ .stmt = stmt, .next_block = pattern.exit_block orelse pattern.subject_block + 1 };
    }

    fn decompileMatchCase(self: *Decompiler, block_id: u32) DecompileError!ast.MatchCase {
        const block = &self.cfg.blocks[block_id];

        // Extract pattern from bytecode
        const pat = try self.extractMatchPattern(block);

        // Find body block (true branch of conditional)
        var body_block: ?u32 = null;
        for (block.successors) |edge| {
            if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                body_block = edge.target;
                break;
            }
        }

        // Find end of body (next case or exit)
        var body_end: u32 = block_id + 1;
        for (block.successors) |edge| {
            if (edge.edge_type == .conditional_false) {
                body_end = edge.target;
                break;
            }
        }

        // Decompile body
        var body: []const *Stmt = &.{};
        if (body_block) |bid| {
            if (bid < body_end) {
                body = try self.decompileStructuredRange(bid, body_end);
            }
        }

        return ast.MatchCase{
            .pattern = pat,
            .guard = null, // TODO: detect guards
            .body = body,
        };
    }

    fn extractMatchPattern(self: *Decompiler, block: *const cfg_mod.BasicBlock) DecompileError!*ast.Pattern {
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        var has_match_seq = false;
        var has_match_map = false;
        var literal_val: ?*Expr = null;

        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .MATCH_SEQUENCE => has_match_seq = true,
                .MATCH_MAPPING => has_match_map = true,
                .LOAD_CONST, .LOAD_SMALL_INT => {
                    try sim.simulate(inst);
                    literal_val = sim.stack.popExpr() catch null;
                },
                .COMPARE_OP => {
                    // Literal match - use the constant
                    if (literal_val) |val| {
                        const pat = try self.allocator.create(ast.Pattern);
                        pat.* = .{ .match_value = val };
                        return pat;
                    }
                },
                .NOP => {
                    // Wildcard pattern
                    const pat = try self.allocator.create(ast.Pattern);
                    pat.* = .{ .match_as = .{ .pattern = null, .name = null } };
                    return pat;
                },
                else => try sim.simulate(inst),
            }
        }

        // Default to wildcard if we can't determine pattern
        const pat = try self.allocator.create(ast.Pattern);
        if (has_match_seq) {
            pat.* = .{ .match_sequence = &.{} };
        } else if (has_match_map) {
            pat.* = .{ .match_mapping = .{ .keys = &.{}, .patterns = &.{}, .rest = null } };
        } else {
            pat.* = .{ .match_as = .{ .pattern = null, .name = null } };
        }
        return pat;
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
                .match_stmt => |p| {
                    const result = try self.decompileMatch(p);
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

        // Get the loop target from the body block's first STORE_* or UNPACK_SEQUENCE
        const body = &self.cfg.blocks[pattern.body_block];
        const a = self.arena.allocator();
        var target: *Expr = undefined;
        var found_target = false;

        for (body.instructions) |inst| {
            switch (inst.opcode) {
                .STORE_FAST => {
                    const name = if (self.code.varnames.len > inst.arg)
                        self.code.varnames[inst.arg]
                    else
                        "_";
                    target = try ast.makeName(a, name, .store);
                    found_target = true;
                    break;
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    const name = if (self.code.names.len > inst.arg)
                        self.code.names[inst.arg]
                    else
                        "_";
                    target = try ast.makeName(a, name, .store);
                    found_target = true;
                    break;
                },
                .UNPACK_SEQUENCE => {
                    // Unpacking target - create tuple with N elements
                    const count = inst.arg;
                    if (count == 0) {
                        // Empty unpacking: for [] in x
                        target = try a.create(Expr);
                        target.* = .{ .tuple = .{ .elts = &.{}, .ctx = .store } };
                    } else {
                        // Need to look at subsequent STORE instructions
                        // For now, create placeholder names
                        var elts = try a.alloc(*Expr, count);
                        for (0..count) |idx| {
                            const placeholder = try a.create(Expr);
                            placeholder.* = .{ .name = .{ .id = "_", .ctx = .store } };
                            elts[idx] = placeholder;
                        }
                        target = try a.create(Expr);
                        target.* = .{ .tuple = .{ .elts = elts, .ctx = .store } };
                    }
                    found_target = true;
                    break;
                },
                else => {},
            }
        }

        if (!found_target) {
            target = try ast.makeName(a, "_", .store);
        }

        // Decompile the body (skip the first STORE_FAST which is the target)
        const body_stmts = try self.decompileForBody(pattern.body_block, pattern.header_block);
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
        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

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
                        try stmts.append(a, s);
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

        return stmts.toOwnedSlice(a);
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
        const a = self.arena.allocator();
        var sim = SimContext.init(a, self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .UNPACK_SEQUENCE => {
                    // Handle empty unpacking (count=0) in for loop targets
                    const count = inst.arg;
                    if (count == 0 and skip_first_store.*) {
                        // Empty unpack as for loop target - just consume the value
                        skip_first_store.* = false;
                        _ = sim.stack.pop(); // Consume iteration value
                        continue;
                    }
                    // Otherwise let it fall through to simulate
                    try sim.simulate(inst);
                },
                .STORE_FAST => {
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        continue;
                    }
                    const name = sim.getLocal(inst.arg) orelse "<unknown>";
                    const value = sim.stack.pop() orelse return error.StackUnderflow;
                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(a, stmt);
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
                        try stmts.append(a, stmt);
                    }
                },
                .JUMP_FORWARD, .JUMP_BACKWARD, .JUMP_BACKWARD_NO_INTERRUPT, .JUMP_ABSOLUTE => {
                    if (loop_header) |header_id| {
                        const exit = self.analyzer.detectLoopExit(block_id, &[_]u32{header_id});
                        switch (exit) {
                            .break_stmt => {
                                const stmt = try self.makeBreak();
                                try stmts.append(a, stmt);
                                return;
                            },
                            .continue_stmt => {
                                const stmt = try self.makeContinue();
                                try stmts.append(a, stmt);
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
                    try stmts.append(a, stmt);
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const value = try sim.objToExpr(obj);
                        const stmt = try self.makeReturn(value);
                        try stmts.append(a, stmt);
                    }
                },
                .POP_TOP => {
                    const value = try sim.stack.popExpr();
                    const stmt = try self.makeExprStmt(value);
                    try stmts.append(a, stmt);
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
                        const body = try self.arena.allocator().alloc(*Stmt, 1);
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
        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

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
                        try stmts.append(a, s);
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

        return stmts.toOwnedSlice(a);
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
        errdefer nested_ptr.deinit();

        _ = try nested_ptr.decompile();

        // Only track after successful decompile - errdefer handles failure cleanup
        try self.nested_decompilers.append(self.allocator, nested_ptr);
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

        const args = try codegen.extractFunctionSignature(a, func.code, func.defaults, func.kw_defaults, func.annotations);

        // Find return annotation
        var returns: ?*Expr = null;
        for (func.annotations) |ann| {
            if (std.mem.eql(u8, ann.name, "return")) {
                returns = ann.value;
                break;
            }
        }

        const decorator_list = try self.takeDecorators(&func.decorators);

        cleanup_func = false;

        const name_copy = try a.dupe(u8, name);

        const stmt = try a.create(Stmt);

        stmt.* = .{ .function_def = .{
            .name = name_copy,
            .args = args,
            .body = body,
            .decorator_list = decorator_list,
            .returns = returns,
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

    /// Create a print statement (Python 2.x).
    fn makePrintStmt(self: *Decompiler, dest: ?*Expr, nl: bool) DecompileError!*Stmt {
        const a = self.arena.allocator();
        const values = try a.alloc(*Expr, self.print_items.items.len);
        @memcpy(values, self.print_items.items);
        self.print_items.clearRetainingCapacity();

        const stmt = try a.create(Stmt);
        stmt.* = .{ .print_stmt = .{
            .values = values,
            .dest = dest,
            .nl = nl,
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

    /// Create unpacking assignment: a, b, c = expr
    fn makeUnpackAssign(self: *Decompiler, names: []const []const u8, value: *Expr) DecompileError!*Stmt {
        const a = self.arena.allocator();

        // Create tuple of Name expressions for targets
        var target_exprs = try std.ArrayList(*Expr).initCapacity(a, names.len);
        for (names) |name| {
            const name_expr = try a.create(Expr);
            name_expr.* = .{ .name = .{ .id = name, .ctx = .store } };
            try target_exprs.append(a, name_expr);
        }

        const tuple_expr = try a.create(Expr);
        tuple_expr.* = .{ .tuple = .{
            .elts = try target_exprs.toOwnedSlice(a),
            .ctx = .store,
        } };

        const targets = try a.alloc(*Expr, 1);
        targets[0] = tuple_expr;

        const stmt = try a.create(Stmt);
        stmt.* = .{ .assign = .{
            .targets = targets,
            .value = value,
            .type_comment = null,
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
    return decompileToSourceWithContext(allocator, code, version, writer, null);
}

/// Decompile with error context output.
pub fn decompileToSourceWithContext(
    allocator: Allocator,
    code: *const pyc.Code,
    version: Version,
    writer: anytype,
    err_writer: ?std.fs.File,
) !void {
    // Handle module-level code
    if (std.mem.eql(u8, code.name, "<module>")) {
        var decompiler = try Decompiler.init(allocator, code, version);
        defer decompiler.deinit();

        const stmts = decompiler.decompile() catch |err| {
            if (err_writer) |ew| {
                if (decompiler.last_error_ctx) |ctx| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Error in {s} at offset {d} ({s}): {s}\n", .{
                        ctx.code_name,
                        ctx.offset,
                        ctx.opcode,
                        @errorName(err),
                    }) catch "Error context unavailable\n";
                    _ = ew.write(msg) catch {};
                }
            }
            return err;
        };
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
