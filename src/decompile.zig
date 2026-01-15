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

/// Check if an opcode is a LOAD instruction.
fn isLoadInstr(op: Opcode) bool {
    return switch (op) {
        .LOAD_NAME, .LOAD_FAST, .LOAD_GLOBAL, .LOAD_DEREF, .LOAD_FAST_BORROW, .LOAD_FAST_CHECK => true,
        else => false,
    };
}

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
    /// Pending chain targets from STORE_ATTR before UNPACK_SEQUENCE.
    pending_chain_targets: std.ArrayList(*Expr),

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
            .pending_chain_targets = .{},
        };
    }

    pub fn deinit(self: *Decompiler) void {
        for (self.nested_decompilers.items) |nested| {
            nested.deinit();
            self.allocator.destroy(nested);
        }
        self.nested_decompilers.deinit(self.allocator);
        self.print_items.deinit(self.allocator);
        self.pending_chain_targets.deinit(self.allocator);
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
            std.mem.eql(u8, name, "END_SEND") or
            std.mem.eql(u8, name, "RAISE_VARARGS") or
            std.mem.eql(u8, name, "DELETE_NAME") or
            std.mem.eql(u8, name, "DELETE_FAST") or
            std.mem.eql(u8, name, "DELETE_GLOBAL") or
            std.mem.eql(u8, name, "DELETE_DEREF");
    }

    /// Try to emit a statement for the given opcode from the current stack state.
    /// Returns the statement if one was emitted, null otherwise.
    fn tryEmitStatement(self: *Decompiler, inst: decoder.Instruction, sim: *SimContext) DecompileError!?*Stmt {
        switch (inst.opcode) {
            .STORE_NAME, .STORE_FAST, .STORE_GLOBAL, .STORE_DEREF => {
                const name = switch (inst.opcode) {
                    .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                    .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                    .STORE_DEREF => sim.getDeref(inst.arg) orelse "<unknown>",
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
            .DELETE_NAME, .DELETE_FAST, .DELETE_GLOBAL, .DELETE_DEREF => {
                const name = switch (inst.opcode) {
                    .DELETE_NAME, .DELETE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                    .DELETE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                    .DELETE_DEREF => sim.getDeref(inst.arg) orelse "<unknown>",
                    else => "<unknown>",
                };
                const a = self.arena.allocator();
                const target = try ast.makeName(a, name, .del);
                const targets = try a.alloc(*Expr, 1);
                targets[0] = target;
                const stmt = try a.create(Stmt);
                stmt.* = .{ .delete = .{ .targets = targets } };
                return stmt;
            },
            .RAISE_VARARGS => {
                // RAISE_VARARGS argc: 0=bare, 1=exc, 2=exc from cause
                if (inst.arg == 0) {
                    const a = self.arena.allocator();
                    const stmt = try a.create(Stmt);
                    stmt.* = .{ .raise_stmt = .{ .exc = null, .cause = null } };
                    return stmt;
                } else if (inst.arg == 1) {
                    const val = sim.stack.pop() orelse return error.StackUnderflow;
                    if (val == .expr) {
                        const a = self.arena.allocator();
                        const stmt = try a.create(Stmt);
                        stmt.* = .{ .raise_stmt = .{ .exc = val.expr, .cause = null } };
                        return stmt;
                    }
                    val.deinit(self.allocator);
                } else if (inst.arg == 2) {
                    const cause_val = sim.stack.pop() orelse return error.StackUnderflow;
                    errdefer cause_val.deinit(self.allocator);
                    const exc_val = sim.stack.pop() orelse return error.StackUnderflow;
                    if (exc_val == .expr and cause_val == .expr) {
                        const a = self.arena.allocator();
                        const stmt = try a.create(Stmt);
                        stmt.* = .{ .raise_stmt = .{ .exc = exc_val.expr, .cause = cause_val.expr } };
                        return stmt;
                    }
                    exc_val.deinit(self.allocator);
                    cause_val.deinit(self.allocator);
                }
                return null;
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
        // For inline comprehensions (Python 3.12+), we need to skip cleanup ops
        // before pushing the expression: END_FOR, POP_TOP, SWAP, STORE_FAST (loop var restore)
        var extra_skip: usize = 0;
        if (self.pending_ternary_expr != null) {
            // Skip cleanup ops at start of block
            const cleanup_insts = block.instructions[skip_first..];
            for (cleanup_insts, 0..) |cleanup_inst, j| {
                switch (cleanup_inst.opcode) {
                    .END_FOR, .POP_TOP, .POP_ITER, .SWAP => {
                        extra_skip += 1;
                    },
                    .STORE_FAST => {
                        // STORE_FAST after SWAP is loop variable restore - skip it
                        if (j > 0 and cleanup_insts[j - 1].opcode == .SWAP) {
                            extra_skip += 1;
                        } else {
                            break;
                        }
                    },
                    else => break,
                }
            }
        }
        if (self.pending_ternary_expr) |expr| {
            try sim.stack.push(.{ .expr = expr });
            self.pending_ternary_expr = null;
        }

        const instructions = block.instructions[skip_first + extra_skip ..];
        var i: usize = 0;
        while (i < instructions.len) : (i += 1) {
            const inst = instructions[i];

            // Stop at POP_EXCEPT - marks end of except handler body, cleanup follows
            if (inst.opcode == .POP_EXCEPT) break;

            errdefer if (self.last_error_ctx == null) {
                self.last_error_ctx = .{
                    .code_name = self.code.name,
                    .block_id = block.id,
                    .offset = inst.offset,
                    .opcode = inst.opcode.name(),
                };
            };
            switch (inst.opcode) {
                .UNPACK_SEQUENCE, .UNPACK_EX => {
                    // Look ahead for N store targets to generate unpacking assignment
                    // Targets can be: STORE_*, or LOAD + STORE_ATTR, or LOAD + STORE_SUBSCR
                    const count = if (inst.opcode == .UNPACK_EX) blk: {
                        const before = inst.arg & 0xFF;
                        const after = (inst.arg >> 8) & 0xFF;
                        break :blk before + 1 + after;
                    } else inst.arg;
                    const seq_expr = try sim.stack.popExpr();
                    const arena = self.arena.allocator();

                    // Collect targets from following instructions
                    var targets = try std.ArrayList(*Expr).initCapacity(arena, count);
                    var skip_count: usize = 0;

                    const star_pos: ?u32 = if (inst.opcode == .UNPACK_EX) blk: {
                        const before = inst.arg & 0xFF;
                        break :blk before;
                    } else null;

                    var j: usize = 0;
                    var instr_idx: usize = i + 1;
                    while (j < count and instr_idx < instructions.len) : (j += 1) {
                        const store_inst = instructions[instr_idx];
                        // STORE_FAST_STORE_FAST: stores two values
                        if (store_inst.opcode == .STORE_FAST_STORE_FAST and j + 1 < count) {
                            const idx1 = (store_inst.arg >> 4) & 0xF;
                            const idx2 = store_inst.arg & 0xF;
                            if (sim.getLocal(idx1)) |n1| {
                                const t1 = try ast.makeName(arena, n1, .store);
                                try targets.append(arena, t1);
                            }
                            if (sim.getLocal(idx2)) |n2| {
                                const t2 = try ast.makeName(arena, n2, .store);
                                try targets.append(arena, t2);
                            }
                            j += 1; // Count as 2 targets
                            skip_count += 1;
                            instr_idx += 1;
                            continue;
                        }
                        // Simple STORE_* instructions
                        const simple_name: ?[]const u8 = switch (store_inst.opcode) {
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(store_inst.arg),
                            .STORE_FAST => sim.getLocal(store_inst.arg),
                            .STORE_DEREF => sim.getDeref(store_inst.arg),
                            else => null,
                        };
                        if (simple_name) |n| {
                            const target = if (star_pos != null and j == star_pos.?) blk: {
                                const starred = try arena.create(Expr);
                                starred.* = .{ .starred = .{
                                    .value = try ast.makeName(arena, n, .store),
                                    .ctx = .store,
                                } };
                                break :blk starred;
                            } else try ast.makeName(arena, n, .store);
                            try targets.append(arena, target);
                            skip_count += 1;
                            instr_idx += 1;
                            continue;
                        }
                        // LOAD + STORE_ATTR pattern: LOAD_FAST self, STORE_ATTR b
                        if (isLoadInstr(store_inst.opcode) and instr_idx + 1 < instructions.len) {
                            const next = instructions[instr_idx + 1];
                            if (next.opcode == .STORE_ATTR) {
                                // Simulate the LOAD to get container expr
                                try sim.simulate(store_inst);
                                const container = sim.stack.pop() orelse break;
                                if (container != .expr) {
                                    container.deinit(sim.allocator);
                                    break;
                                }
                                const attr_name = sim.getName(next.arg) orelse break;
                                const target = try ast.makeAttribute(arena, container.expr, attr_name, .store);
                                try targets.append(arena, target);
                                skip_count += 2;
                                instr_idx += 2;
                                continue;
                            } else if (next.opcode == .STORE_SUBSCR and instr_idx + 2 < instructions.len) {
                                // LOAD container, LOAD index, STORE_SUBSCR
                                const idx_inst = instructions[instr_idx + 1];
                                if (isLoadInstr(idx_inst.opcode) or idx_inst.opcode == .LOAD_SMALL_INT or idx_inst.opcode == .LOAD_CONST) {
                                    try sim.simulate(store_inst);
                                    try sim.simulate(idx_inst);
                                    const idx_val = sim.stack.pop() orelse break;
                                    const cont_val = sim.stack.pop() orelse {
                                        idx_val.deinit(sim.allocator);
                                        break;
                                    };
                                    if (cont_val != .expr or idx_val != .expr) {
                                        cont_val.deinit(sim.allocator);
                                        idx_val.deinit(sim.allocator);
                                        break;
                                    }
                                    const target = try ast.makeSubscript(arena, cont_val.expr, idx_val.expr, .store);
                                    try targets.append(arena, target);
                                    skip_count += 3;
                                    instr_idx += 3;
                                    continue;
                                }
                            }
                        }
                        break;
                    }

                    if (targets.items.len == count) {
                        // Check for pending chain targets from preceding STORE_ATTR
                        const has_pending = self.pending_chain_targets.items.len > 0;
                        if (has_pending) {
                            // Combine pending targets with unpack targets
                            // Create: self.a = (self.b, self.c) = expr
                            const all_targets = try arena.alloc(*Expr, 1 + self.pending_chain_targets.items.len);

                            // First, create tuple from unpack targets
                            const tuple_expr = try arena.create(Expr);
                            tuple_expr.* = .{ .tuple = .{
                                .elts = try arena.dupe(*Expr, targets.items),
                                .ctx = .store,
                            } };

                            // Put pending targets first (leftmost in chain), then tuple
                            for (self.pending_chain_targets.items, 0..) |t, idx| {
                                all_targets[idx] = t;
                            }
                            all_targets[self.pending_chain_targets.items.len] = tuple_expr;
                            self.pending_chain_targets.clearRetainingCapacity();

                            const stmt = try arena.create(Stmt);
                            stmt.* = .{ .assign = .{
                                .targets = all_targets,
                                .value = seq_expr,
                                .type_comment = null,
                            } };
                            try stmts.append(self.allocator, stmt);
                            i += skip_count;
                            continue;
                        }
                        // Generate unpacking assignment: a, b, c = expr
                        const stmt = try self.makeUnpackAssignExprs(targets.items, seq_expr);
                        try stmts.append(self.allocator, stmt);
                        i += skip_count; // Skip the processed instructions
                    } else {
                        // Fallback: push unknown for each element
                        for (targets.items) |t| {
                            t.deinit(arena);
                            arena.destroy(t);
                        }
                        var k: u32 = 0;
                        while (k < count) : (k += 1) {
                            try sim.stack.push(.unknown);
                        }
                    }
                },
                .STORE_NAME, .STORE_FAST, .STORE_GLOBAL, .STORE_DEREF => {
                    // Check for chain assignment pattern: DUP_TOP before STORE indicates chained assignment
                    const real_idx = skip_first + i;
                    const prev_was_dup = if (real_idx > 0) blk: {
                        const prev = block.instructions[real_idx - 1];
                        break :blk prev.opcode == .DUP_TOP or prev.opcode == .COPY;
                    } else false;

                    if (prev_was_dup) {
                        // This is a chain assignment. Collect all targets.
                        const arena = self.arena.allocator();
                        var targets: std.ArrayList(*Expr) = .{};

                        // Add current target
                        const first_name = switch (inst.opcode) {
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                            .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                            .STORE_DEREF => sim.getDeref(inst.arg) orelse "<unknown>",
                            else => "<unknown>",
                        };
                        const first_target = try ast.makeName(arena, first_name, .store);
                        try targets.append(arena, first_target);

                        // Pop one value (the dup'd copy) - don't deinit, arena-allocated
                        _ = sim.stack.pop() orelse return error.StackUnderflow;

                        // Look ahead for more chain: (DUP_TOP + STORE)* STORE
                        var j: usize = i + 1;
                        while (j < instructions.len) {
                            const next_inst = instructions[j];
                            if (next_inst.opcode == .DUP_TOP or next_inst.opcode == .COPY) {
                                // DUP - check what follows: could be STORE or UNPACK_SEQUENCE
                                try sim.simulate(next_inst);
                                if (j + 1 < instructions.len) {
                                    const following = instructions[j + 1];
                                    if (following.opcode == .STORE_NAME or
                                        following.opcode == .STORE_FAST or
                                        following.opcode == .STORE_GLOBAL or
                                        following.opcode == .STORE_DEREF)
                                    {
                                        const store_name: ?[]const u8 = switch (following.opcode) {
                                            .STORE_NAME, .STORE_GLOBAL => sim.getName(following.arg),
                                            .STORE_FAST => sim.getLocal(following.arg),
                                            .STORE_DEREF => sim.getDeref(following.arg),
                                            else => null,
                                        };
                                        if (store_name) |sn| {
                                            const target = try ast.makeName(arena, sn, .store);
                                            try targets.append(arena, target);
                                            // Pop dup'd value (from the simulated DUP)
                                            _ = sim.stack.pop() orelse return error.StackUnderflow;
                                            j += 2;
                                            continue;
                                        }
                                    } else if (following.opcode == .STORE_FAST_STORE_FAST) {
                                        // DUP + STORE_FAST_STORE_FAST: stores two values
                                        const idx1 = (following.arg >> 4) & 0xF;
                                        const idx2 = following.arg & 0xF;
                                        if (sim.getLocal(idx1)) |n1| {
                                            const t1 = try ast.makeName(arena, n1, .store);
                                            try targets.append(arena, t1);
                                        }
                                        if (sim.getLocal(idx2)) |n2| {
                                            const t2 = try ast.makeName(arena, n2, .store);
                                            try targets.append(arena, t2);
                                        }
                                        // Pop dup'd value
                                        _ = sim.stack.pop() orelse return error.StackUnderflow;
                                        j += 2;
                                        continue;
                                    } else if (following.opcode == .UNPACK_SEQUENCE) {
                                        // DUP + UNPACK: add tuple target (may be subscripts/attrs)
                                        const unpack_cnt = following.arg;
                                        var tup_targets: std.ArrayList(*Expr) = .{};
                                        try tup_targets.ensureTotalCapacity(arena, unpack_cnt);

                                        var kk: usize = j + 2; // Start after DUP + UNPACK
                                        var found: usize = 0;
                                        while (found < unpack_cnt and kk < instructions.len) {
                                            const us2 = instructions[kk];
                                            // STORE_FAST_STORE_FAST: stores two values
                                            if (us2.opcode == .STORE_FAST_STORE_FAST and found + 1 < unpack_cnt) {
                                                const idx1 = (us2.arg >> 4) & 0xF;
                                                const idx2 = us2.arg & 0xF;
                                                if (sim.getLocal(idx1)) |n1| {
                                                    const t1 = try ast.makeName(arena, n1, .store);
                                                    try tup_targets.append(arena, t1);
                                                    found += 1;
                                                }
                                                if (sim.getLocal(idx2)) |n2| {
                                                    const t2 = try ast.makeName(arena, n2, .store);
                                                    try tup_targets.append(arena, t2);
                                                    found += 1;
                                                }
                                                kk += 1;
                                                continue;
                                            }
                                            const un2: ?[]const u8 = switch (us2.opcode) {
                                                .STORE_NAME, .STORE_GLOBAL => sim.getName(us2.arg),
                                                .STORE_FAST => sim.getLocal(us2.arg),
                                                .STORE_DEREF => sim.getDeref(us2.arg),
                                                else => null,
                                            };
                                            if (un2) |nm| {
                                                const tgt = try ast.makeName(self.allocator, nm, .store);
                                                try tup_targets.append(arena, tgt);
                                                found += 1;
                                                kk += 1;
                                                continue;
                                            }
                                            // Try subscript/attr target
                                            if (us2.opcode == .LOAD_NAME or us2.opcode == .LOAD_FAST or
                                                us2.opcode == .LOAD_GLOBAL or us2.opcode == .LOAD_DEREF)
                                            {
                                                if (try self.tryParseSubscriptTarget(sim, instructions, kk, arena)) |result| {
                                                    try tup_targets.append(arena, result.target);
                                                    found += 1;
                                                    kk = result.next_idx;
                                                    continue;
                                                }
                                            }
                                            break;
                                        }

                                        if (tup_targets.items.len == unpack_cnt) {
                                            const tup_expr = try arena.create(Expr);
                                            tup_expr.* = .{ .tuple = .{ .elts = tup_targets.items, .ctx = .store } };
                                            try targets.append(arena, tup_expr);
                                            // Pop dup'd value
                                            _ = sim.stack.pop() orelse return error.StackUnderflow;
                                            j = kk;
                                            continue;
                                        }
                                    } else if (following.opcode == .LOAD_NAME or
                                        following.opcode == .LOAD_FAST or
                                        following.opcode == .LOAD_GLOBAL or
                                        following.opcode == .LOAD_DEREF)
                                    {
                                        // Possibly DUP + LOAD container + LOAD key + STORE_SUBSCR
                                        // Or DUP + LOAD container + LOAD attr + STORE_ATTR
                                        if (try self.tryParseSubscriptTarget(sim, instructions, j + 1, arena)) |result| {
                                            try targets.append(arena, result.target);
                                            // Pop dup'd value
                                            _ = sim.stack.pop() orelse return error.StackUnderflow;
                                            j = result.next_idx;
                                            continue;
                                        }
                                    }
                                }
                                break;
                            } else if (next_inst.opcode == .STORE_NAME or
                                next_inst.opcode == .STORE_FAST or
                                next_inst.opcode == .STORE_GLOBAL or
                                next_inst.opcode == .STORE_DEREF)
                            {
                                // Final store in chain (no preceding DUP)
                                const store_name: ?[]const u8 = switch (next_inst.opcode) {
                                    .STORE_NAME, .STORE_GLOBAL => sim.getName(next_inst.arg),
                                    .STORE_FAST => sim.getLocal(next_inst.arg),
                                    .STORE_DEREF => sim.getDeref(next_inst.arg),
                                    else => null,
                                };
                                if (store_name) |sn| {
                                    const target = try ast.makeName(arena, sn, .store);
                                    try targets.append(arena, target);
                                    j += 1;
                                }
                                break;
                            } else if (next_inst.opcode == .LOAD_NAME or
                                next_inst.opcode == .LOAD_FAST or
                                next_inst.opcode == .LOAD_GLOBAL or
                                next_inst.opcode == .LOAD_DEREF)
                            {
                                // Possibly final subscript/attr target: LOAD container + LOAD key + STORE_SUBSCR
                                if (try self.tryParseSubscriptTarget(sim, instructions, j, arena)) |result| {
                                    try targets.append(arena, result.target);
                                    j = result.next_idx;
                                }
                                break;
                            } else if (next_inst.opcode == .UNPACK_SEQUENCE) {
                                // Chain with unpacking: a = [b, c] = value or a[0] = (b[x], c[3]) = value
                                // Handle UNPACK_SEQUENCE followed by STORE_*, subscripts, or attrs
                                const unpack_count = next_inst.arg;
                                var tuple_targets: std.ArrayList(*Expr) = .{};
                                try tuple_targets.ensureTotalCapacity(arena, unpack_count);

                                var k: usize = j + 1; // Start after UNPACK_SEQUENCE
                                var targets_found: usize = 0;
                                while (targets_found < unpack_count and k < instructions.len) {
                                    const us = instructions[k];
                                    // STORE_FAST_STORE_FAST: stores two values at once
                                    if (us.opcode == .STORE_FAST_STORE_FAST and targets_found + 1 < unpack_count) {
                                        const idx1 = (us.arg >> 4) & 0xF;
                                        const idx2 = us.arg & 0xF;
                                        if (sim.getLocal(idx1)) |n1| {
                                            const t1 = try ast.makeName(arena, n1, .store);
                                            try tuple_targets.append(arena, t1);
                                            targets_found += 1;
                                        }
                                        if (sim.getLocal(idx2)) |n2| {
                                            const t2 = try ast.makeName(arena, n2, .store);
                                            try tuple_targets.append(arena, t2);
                                            targets_found += 1;
                                        }
                                        k += 1;
                                        continue;
                                    }
                                    // Try simple STORE_* first
                                    const un: ?[]const u8 = switch (us.opcode) {
                                        .STORE_NAME, .STORE_GLOBAL => sim.getName(us.arg),
                                        .STORE_FAST => sim.getLocal(us.arg),
                                        .STORE_DEREF => sim.getDeref(us.arg),
                                        else => null,
                                    };
                                    if (un) |name| {
                                        const t = try ast.makeName(arena, name, .store);
                                        try tuple_targets.append(arena, t);
                                        targets_found += 1;
                                        k += 1;
                                        continue;
                                    }
                                    // Try subscript/attr target: LOAD container, (LOAD key + STORE_SUBSCR) or STORE_ATTR
                                    if (us.opcode == .LOAD_NAME or us.opcode == .LOAD_FAST or
                                        us.opcode == .LOAD_GLOBAL or us.opcode == .LOAD_DEREF)
                                    {
                                        if (try self.tryParseSubscriptTarget(sim, instructions, k, arena)) |result| {
                                            try tuple_targets.append(arena, result.target);
                                            targets_found += 1;
                                            k = result.next_idx;
                                            continue;
                                        }
                                    }
                                    break; // Unknown instruction type
                                }

                                if (tuple_targets.items.len == unpack_count) {
                                    // Create tuple/list target
                                    const tuple_expr = try arena.create(Expr);
                                    tuple_expr.* = .{ .tuple = .{ .elts = tuple_targets.items, .ctx = .store } };
                                    try targets.append(arena, tuple_expr);
                                    j = k;
                                    // UNPACK_SEQUENCE consumes the final value; don't pop here,
                                    // the final pop at the end will get it.
                                }
                                break;
                            } else {
                                break;
                            }
                        }

                        // Get the actual value (last one on stack)
                        const value = sim.stack.pop() orelse return error.StackUnderflow;

                        if (value == .expr) {
                            // Create chain assignment: target1 = target2 = ... = value
                            const stmt = try arena.create(Stmt);
                            stmt.* = .{ .assign = .{
                                .targets = targets.items,
                                .value = value.expr,
                                .type_comment = null,
                            } };
                            try stmts.append(self.allocator, stmt);
                        }

                        // Skip processed instructions
                        i = j - 1; // -1 because loop will increment
                        continue;
                    }

                    // Regular single assignment
                    const name = switch (inst.opcode) {
                        .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                        .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                        .STORE_DEREF => sim.getDeref(inst.arg) orelse "<unknown>",
                        else => "<unknown>",
                    };
                    const value = sim.stack.pop() orelse return error.StackUnderflow;
                    errdefer value.deinit(self.allocator);

                    // Check for augmented assignment: x = x + 5 -> x += 5
                    if (value == .expr and value.expr.* == .bin_op) {
                        const binop = &value.expr.bin_op;
                        if (binop.left.* == .name and std.mem.eql(u8, binop.left.name.id, name)) {
                            const arena = self.arena.allocator();
                            binop.left.deinit(arena);
                            arena.destroy(binop.left);
                            const stmt = try arena.create(Stmt);
                            const target = try ast.makeName(arena, name, .store);
                            stmt.* = .{ .aug_assign = .{
                                .target = target,
                                .op = binop.op,
                                .value = binop.right,
                            } };
                            arena.destroy(value.expr);
                            try stmts.append(self.allocator, stmt);
                            continue;
                        }
                    }

                    // Check for augmented assignment: x = x + 5 -> x += 5
                    if (value == .expr and value.expr.* == .bin_op) {
                        const binop = &value.expr.bin_op;
                        if (binop.left.* == .name and std.mem.eql(u8, binop.left.name.id, name)) {
                            const arena = self.arena.allocator();
                            binop.left.deinit(arena);
                            arena.destroy(binop.left);
                            const stmt = try arena.create(Stmt);
                            const target = try ast.makeName(arena, name, .store);
                            stmt.* = .{ .aug_assign = .{
                                .target = target,
                                .op = binop.op,
                                .value = binop.right,
                            } };
                            arena.destroy(value.expr);
                            try stmts.append(self.allocator, stmt);
                            continue;
                        }
                    }

                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .STORE_SUBSCR => {
                    // STORE_SUBSCR: TOS1[TOS] = TOS2
                    // Stack: key, container, value
                    // Check for chain: look back for DUP_TOP/COPY, skipping CACHE instructions
                    const real_idx = skip_first + i;
                    const is_chain = blk: {
                        // Search backwards for DUP_TOP/COPY, skipping CACHE
                        var back: usize = 1;
                        var non_cache_count: usize = 0;
                        while (back <= real_idx and non_cache_count < 3) : (back += 1) {
                            const prev_op = block.instructions[real_idx - back].opcode;
                            if (prev_op == .CACHE) continue;
                            non_cache_count += 1;
                            if (non_cache_count == 3) {
                                break :blk prev_op == .DUP_TOP or prev_op == .COPY;
                            }
                        }
                        break :blk false;
                    };

                    if (is_chain) {
                        // This is a subscript chain assignment
                        const arena = self.arena.allocator();
                        var targets: std.ArrayList(*Expr) = .{};

                        // Build first target from current instruction's context
                        const key_val = sim.stack.pop() orelse return error.StackUnderflow;
                        const container_val = sim.stack.pop() orelse return error.StackUnderflow;
                        _ = sim.stack.pop() orelse return error.StackUnderflow; // pop dup'd value

                        if (key_val == .expr and container_val == .expr) {
                            const first_target = try arena.create(Expr);
                            first_target.* = .{ .subscript = .{
                                .value = container_val.expr,
                                .slice = key_val.expr,
                                .ctx = .store,
                            } };
                            try targets.append(arena, first_target);
                        }

                        // Look ahead for more chain targets (subscripts, names, unpacking)
                        var j: usize = i + 1;
                        while (j < instructions.len) {
                            const next_inst = instructions[j];
                            if (next_inst.opcode == .DUP_TOP or next_inst.opcode == .COPY) {
                                try sim.simulate(next_inst);
                                // Check what follows the DUP
                                if (j + 1 < instructions.len) {
                                    const after_dup = instructions[j + 1];
                                    // Handle STORE_NAME/FAST/GLOBAL/DEREF after DUP
                                    if (after_dup.opcode == .STORE_NAME or
                                        after_dup.opcode == .STORE_FAST or
                                        after_dup.opcode == .STORE_GLOBAL or
                                        after_dup.opcode == .STORE_DEREF)
                                    {
                                        const store_name: ?[]const u8 = switch (after_dup.opcode) {
                                            .STORE_NAME, .STORE_GLOBAL => sim.getName(after_dup.arg),
                                            .STORE_FAST => sim.getLocal(after_dup.arg),
                                            .STORE_DEREF => sim.getDeref(after_dup.arg),
                                            else => null,
                                        };
                                        if (store_name) |sn| {
                                            const target = try ast.makeName(arena, sn, .store);
                                            try targets.append(arena, target);
                                            _ = sim.stack.pop() orelse return error.StackUnderflow;
                                            j += 2;
                                            continue;
                                        }
                                    } else if (after_dup.opcode == .UNPACK_SEQUENCE) {
                                        // DUP + UNPACK_SEQUENCE: handle tuple unpacking
                                        _ = sim.stack.pop() orelse return error.StackUnderflow; // Pop dup'd value
                                        const unpack_count = after_dup.arg;
                                        var tuple_targets: std.ArrayList(*Expr) = .{};
                                        try tuple_targets.ensureTotalCapacity(arena, unpack_count);

                                        var k: usize = j + 2; // Start after DUP + UNPACK_SEQUENCE
                                        var targets_found: usize = 0;
                                        while (targets_found < unpack_count and k < instructions.len) {
                                            const us = instructions[k];
                                            const un: ?[]const u8 = switch (us.opcode) {
                                                .STORE_NAME, .STORE_GLOBAL => sim.getName(us.arg),
                                                .STORE_FAST => sim.getLocal(us.arg),
                                                .STORE_DEREF => sim.getDeref(us.arg),
                                                else => null,
                                            };
                                            if (un) |name| {
                                                const t = try ast.makeName(arena, name, .store);
                                                try tuple_targets.append(arena, t);
                                                targets_found += 1;
                                                k += 1;
                                                continue;
                                            }
                                            if (us.opcode == .LOAD_NAME or us.opcode == .LOAD_FAST or
                                                us.opcode == .LOAD_GLOBAL or us.opcode == .LOAD_DEREF)
                                            {
                                                if (try self.tryParseSubscriptTarget(sim, instructions, k, arena)) |result| {
                                                    try tuple_targets.append(arena, result.target);
                                                    targets_found += 1;
                                                    k = result.next_idx;
                                                    continue;
                                                }
                                            }
                                            break;
                                        }

                                        if (tuple_targets.items.len == unpack_count) {
                                            const tuple_expr = try arena.create(Expr);
                                            tuple_expr.* = .{ .tuple = .{ .elts = tuple_targets.items, .ctx = .store } };
                                            try targets.append(arena, tuple_expr);
                                            j = k;
                                            continue;
                                        }
                                        break;
                                    }
                                    // Try subscript/attr target
                                    if (try self.tryParseSubscriptTarget(sim, instructions, j + 1, arena)) |result| {
                                        try targets.append(arena, result.target);
                                        _ = sim.stack.pop() orelse return error.StackUnderflow;
                                        j = result.next_idx;
                                        continue;
                                    }
                                }
                                break;
                            } else if (next_inst.opcode == .UNPACK_SEQUENCE) {
                                // Handle tuple unpacking to subscripts: (b[x], c[3])
                                const unpack_count = next_inst.arg;
                                var tuple_targets: std.ArrayList(*Expr) = .{};
                                try tuple_targets.ensureTotalCapacity(arena, unpack_count);

                                var k: usize = j + 1; // Start after UNPACK_SEQUENCE
                                var targets_found: usize = 0;
                                while (targets_found < unpack_count and k < instructions.len) {
                                    const us = instructions[k];
                                    // Try simple STORE_* first
                                    const un: ?[]const u8 = switch (us.opcode) {
                                        .STORE_NAME, .STORE_GLOBAL => sim.getName(us.arg),
                                        .STORE_FAST => sim.getLocal(us.arg),
                                        .STORE_DEREF => sim.getDeref(us.arg),
                                        else => null,
                                    };
                                    if (un) |name| {
                                        const t = try ast.makeName(arena, name, .store);
                                        try tuple_targets.append(arena, t);
                                        targets_found += 1;
                                        k += 1;
                                        continue;
                                    }
                                    // Try subscript/attr target
                                    if (us.opcode == .LOAD_NAME or us.opcode == .LOAD_FAST or
                                        us.opcode == .LOAD_GLOBAL or us.opcode == .LOAD_DEREF)
                                    {
                                        if (try self.tryParseSubscriptTarget(sim, instructions, k, arena)) |result| {
                                            try tuple_targets.append(arena, result.target);
                                            targets_found += 1;
                                            k = result.next_idx;
                                            continue;
                                        }
                                    }
                                    break;
                                }

                                if (tuple_targets.items.len == unpack_count) {
                                    const tuple_expr = try arena.create(Expr);
                                    tuple_expr.* = .{ .tuple = .{ .elts = tuple_targets.items, .ctx = .store } };
                                    try targets.append(arena, tuple_expr);
                                    j = k;
                                }
                                break;
                            } else if (next_inst.opcode == .LOAD_NAME or
                                next_inst.opcode == .LOAD_FAST or
                                next_inst.opcode == .LOAD_GLOBAL or
                                next_inst.opcode == .LOAD_CONST)
                            {
                                // Final subscript target (no DUP)
                                if (try self.tryParseSubscriptTarget(sim, instructions, j, arena)) |result| {
                                    try targets.append(arena, result.target);
                                    j = result.next_idx;
                                }
                                break;
                            } else if (next_inst.opcode == .STORE_NAME or
                                next_inst.opcode == .STORE_FAST or
                                next_inst.opcode == .STORE_GLOBAL or
                                next_inst.opcode == .STORE_DEREF)
                            {
                                // Final simple name target (no DUP)
                                const store_name: ?[]const u8 = switch (next_inst.opcode) {
                                    .STORE_NAME, .STORE_GLOBAL => sim.getName(next_inst.arg),
                                    .STORE_FAST => sim.getLocal(next_inst.arg),
                                    .STORE_DEREF => sim.getDeref(next_inst.arg),
                                    else => null,
                                };
                                if (store_name) |sn| {
                                    const target = try ast.makeName(arena, sn, .store);
                                    try targets.append(arena, target);
                                    j += 1;
                                }
                                break;
                            } else {
                                break;
                            }
                        }

                        // Get the value
                        const value = sim.stack.pop() orelse return error.StackUnderflow;
                        if (value == .expr and targets.items.len > 0) {
                            const stmt = try arena.create(Stmt);
                            stmt.* = .{ .assign = .{
                                .targets = targets.items,
                                .value = value.expr,
                                .type_comment = null,
                            } };
                            try stmts.append(self.allocator, stmt);
                        }
                        i = j - 1;
                        continue;
                    }

                    // Regular single subscript assignment
                    const key_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };
                    const container_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };
                    const value_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };

                    // All three must be expressions to generate assignment
                    const key = if (key_val == .expr) key_val.expr else continue;
                    const container = if (container_val == .expr) container_val.expr else continue;
                    const value = if (value_val == .expr) value_val.expr else continue;

                    const a = self.arena.allocator();

                    // Check for variable annotation pattern: __annotations__['varname'] = type
                    if (container.* == .name and std.mem.eql(u8, container.name.id, "__annotations__") and
                        key.* == .constant and key.constant == .string)
                    {
                        const var_name = key.constant.string;
                        const target = try ast.makeName(a, var_name, .store);

                        // Check if previous statement was an assignment to the same variable
                        // Pattern: x = value; __annotations__['x'] = type => x: type = value
                        var assign_value: ?*Expr = null;
                        if (stmts.items.len > 0) {
                            const prev = stmts.items[stmts.items.len - 1];
                            if (prev.* == .assign and prev.assign.targets.len == 1) {
                                const prev_target = prev.assign.targets[0];
                                if (prev_target.* == .name and std.mem.eql(u8, prev_target.name.id, var_name)) {
                                    assign_value = prev.assign.value;
                                    // Remove the previous assignment
                                    _ = stmts.pop();
                                }
                            }
                        }

                        const stmt = try a.create(Stmt);
                        stmt.* = .{ .ann_assign = .{
                            .target = target,
                            .annotation = value,
                            .value = assign_value,
                            .simple = true,
                        } };
                        try stmts.append(self.allocator, stmt);
                    } else {
                        const subscript = try a.create(Expr);
                        subscript.* = .{ .subscript = .{
                            .value = container,
                            .slice = key,
                            .ctx = .store,
                        } };
                        const stmt = try self.makeAssign(subscript, value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .STORE_SLICE => {
                    // STORE_SLICE (3.12+): TOS3[TOS2:TOS1] = TOS
                    // Stack: stop, start, container, value
                    // All stack values are arena-allocated, so no manual cleanup needed
                    const stop_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };
                    const start_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };
                    const container_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };
                    const value_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };

                    // All four must be expressions to generate assignment
                    const stop = if (stop_val == .expr) stop_val.expr else continue;
                    const start = if (start_val == .expr) start_val.expr else continue;
                    const container = if (container_val == .expr) container_val.expr else continue;
                    const value = if (value_val == .expr) value_val.expr else continue;

                    const a = self.arena.allocator();
                    // Build slice expression
                    const slice_expr = try a.create(Expr);
                    const lower = if (start.* == .constant and start.constant == .none) null else start;
                    const upper = if (stop.* == .constant and stop.constant == .none) null else stop;
                    slice_expr.* = .{ .slice = .{ .lower = lower, .upper = upper, .step = null } };

                    const subscript = try a.create(Expr);
                    subscript.* = .{ .subscript = .{
                        .value = container,
                        .slice = slice_expr,
                        .ctx = .store,
                    } };
                    const stmt = try self.makeAssign(subscript, value);
                    try stmts.append(self.allocator, stmt);
                },
                .STORE_ATTR => {
                    // STORE_ATTR: TOS.attr = TOS1
                    // Stack: container, value
                    // Check for chain: 2 instructions back should be DUP_TOP
                    // Pattern: DUP_TOP, LOAD container, STORE_ATTR
                    const real_idx = skip_first + i;
                    const has_dup_before = if (real_idx >= 2) blk: {
                        const maybe_dup = block.instructions[real_idx - 2];
                        break :blk maybe_dup.opcode == .DUP_TOP or maybe_dup.opcode == .COPY;
                    } else false;
                    const next_is_unpack = if (i + 1 < instructions.len)
                        instructions[i + 1].opcode == .UNPACK_SEQUENCE
                    else
                        false;

                    // If part of a chain followed by UNPACK_SEQUENCE, defer to UNPACK handler
                    if (has_dup_before and next_is_unpack) {
                        const arena = self.arena.allocator();
                        const container_val = sim.stack.pop() orelse return error.StackUnderflow;
                        _ = sim.stack.pop() orelse return error.StackUnderflow; // pop dup'd value
                        if (container_val == .expr) {
                            const attr_name = sim.getName(inst.arg) orelse "<unknown>";
                            const target = try ast.makeAttribute(arena, container_val.expr, attr_name, .store);
                            try self.pending_chain_targets.append(self.allocator, target);
                        }
                        continue;
                    }

                    const is_chain = has_dup_before;

                    if (is_chain) {
                        // This is an attribute chain assignment
                        const arena = self.arena.allocator();
                        var targets: std.ArrayList(*Expr) = .{};

                        // Build first target from current instruction's context
                        const container_val = sim.stack.pop() orelse return error.StackUnderflow;
                        _ = sim.stack.pop() orelse return error.StackUnderflow; // pop dup'd value

                        if (container_val == .expr) {
                            const attr_name = sim.getName(inst.arg) orelse "<unknown>";
                            const first_target = try arena.create(Expr);
                            first_target.* = .{ .attribute = .{
                                .value = container_val.expr,
                                .attr = attr_name,
                                .ctx = .store,
                            } };
                            try targets.append(arena, first_target);
                        }

                        // Look ahead for more attribute chain targets
                        var j: usize = i + 1;
                        while (j < instructions.len) {
                            const next_inst = instructions[j];
                            if (next_inst.opcode == .DUP_TOP or next_inst.opcode == .COPY) {
                                // DUP + attr target
                                try sim.simulate(next_inst);
                                if (j + 2 < instructions.len) {
                                    const load_inst = instructions[j + 1];
                                    const store_inst = instructions[j + 2];
                                    if (store_inst.opcode == .STORE_ATTR) {
                                        try sim.simulate(load_inst);
                                        const cont_val = sim.stack.pop() orelse return error.StackUnderflow;
                                        _ = sim.stack.pop() orelse return error.StackUnderflow;
                                        if (cont_val == .expr) {
                                            const attr = sim.getName(store_inst.arg) orelse "<unknown>";
                                            const target = try arena.create(Expr);
                                            target.* = .{ .attribute = .{
                                                .value = cont_val.expr,
                                                .attr = attr,
                                                .ctx = .store,
                                            } };
                                            try targets.append(arena, target);
                                        }
                                        j += 3;
                                        continue;
                                    }
                                }
                                break;
                            } else if (next_inst.opcode == .LOAD_NAME or
                                next_inst.opcode == .LOAD_FAST or
                                next_inst.opcode == .LOAD_GLOBAL or
                                next_inst.opcode == .LOAD_DEREF)
                            {
                                // Final attr target (no DUP)
                                if (j + 1 < instructions.len and instructions[j + 1].opcode == .STORE_ATTR) {
                                    try sim.simulate(next_inst);
                                    const cont_val = sim.stack.pop() orelse return error.StackUnderflow;
                                    if (cont_val == .expr) {
                                        const attr = sim.getName(instructions[j + 1].arg) orelse "<unknown>";
                                        const target = try arena.create(Expr);
                                        target.* = .{ .attribute = .{
                                            .value = cont_val.expr,
                                            .attr = attr,
                                            .ctx = .store,
                                        } };
                                        try targets.append(arena, target);
                                    }
                                    j += 2;
                                }
                                break;
                            } else {
                                break;
                            }
                        }

                        // Get the value
                        const value = sim.stack.pop() orelse return error.StackUnderflow;
                        if (value == .expr and targets.items.len > 0) {
                            const stmt = try arena.create(Stmt);
                            stmt.* = .{ .assign = .{
                                .targets = targets.items,
                                .value = value.expr,
                                .type_comment = null,
                            } };
                            try stmts.append(self.allocator, stmt);
                        }
                        i = j - 1;
                        continue;
                    }

                    // Regular single attribute assignment
                    const container_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };
                    const value_val = sim.stack.pop() orelse {
                        try sim.simulate(inst);
                        continue;
                    };

                    const container = if (container_val == .expr) container_val.expr else continue;
                    const value = if (value_val == .expr) value_val.expr else continue;

                    const a = self.arena.allocator();
                    const attr_name = sim.getName(inst.arg) orelse "<unknown>";
                    const attr_expr = try a.create(Expr);
                    attr_expr.* = .{ .attribute = .{
                        .value = container,
                        .attr = attr_name,
                        .ctx = .store,
                    } };
                    const stmt = try self.makeAssign(attr_expr, value);
                    try stmts.append(self.allocator, stmt);
                },
                .RETURN_VALUE => {
                    const value = try sim.stack.popExpr();
                    // Skip 'return None' at module level (implicit return)
                    if (self.isModuleLevel() and value.* == .constant and value.constant == .none) {
                        continue;
                    }
                    const stmt = try self.makeReturn(value);
                    try stmts.append(self.allocator, stmt);
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const value = try sim.objToExpr(obj);
                        // Skip 'return None' at module level (implicit return)
                        if (self.isModuleLevel() and value.* == .constant and value.constant == .none) {
                            continue;
                        }
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .POP_TOP => {
                    if (sim.stack.len() == 0) {
                        if (self.allowsEmptyPop(block)) continue;
                        return error.StackUnderflow;
                    }
                    const val = sim.stack.pop().?;
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
                .RAISE_VARARGS, .DELETE_NAME, .DELETE_FAST, .DELETE_GLOBAL, .DELETE_DEREF => {
                    if (try self.tryEmitStatement(inst, sim)) |stmt| {
                        try stmts.append(self.allocator, stmt);
                    }
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

    fn simulateValueExprSkip(
        self: *Decompiler,
        block_id: u32,
        base_vals: []const StackValue,
        skip: usize,
    ) DecompileError!?*Expr {
        if (block_id >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[block_id];
        if (skip > block.instructions.len) return null;

        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (base_vals) |val| {
            try sim.stack.push(try sim.cloneStackValue(val));
        }

        for (block.instructions[skip..]) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (inst.isUnconditionalJump()) break;
            if (isStatementOpcode(inst.opcode)) break;
            try sim.simulate(inst);
        }

        if (sim.stack.len() != base_vals.len + 1) return null;
        const expr = sim.stack.popExpr() catch return null;
        return expr;
    }

    fn simulateBoolOpCondExpr(
        self: *Decompiler,
        block_id: u32,
        base_vals: []const StackValue,
        skip: usize,
        kind: ctrl.BoolOpKind,
    ) DecompileError!?*Expr {
        if (block_id >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[block_id];
        if (skip > block.instructions.len) return null;

        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
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
            if (isStatementOpcode(inst.opcode)) return null;
            try sim.simulate(inst);
        }

        const expr = sim.stack.popExpr() catch return null;
        if (sim.stack.len() != base_vals.len) return null;
        return expr;
    }

    fn boolOpBlockSkip(
        self: *Decompiler,
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

    const CondSim = struct {
        expr: *Expr,
        base_vals: []StackValue,
    };

    fn initCondSim(
        self: *Decompiler,
        block_id: u32,
        stmts: *std.ArrayList(*Stmt),
    ) DecompileError!?CondSim {
        if (block_id >= self.cfg.blocks.len) return null;
        const cond_block = &self.cfg.blocks[block_id];

        var cond_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer cond_sim.deinit();

        if (self.pending_ternary_expr) |expr| {
            try cond_sim.stack.push(.{ .expr = expr });
            self.pending_ternary_expr = null;
        }

        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (isStatementOpcode(inst.opcode)) {
                if (try self.tryEmitStatement(inst, &cond_sim)) |stmt| {
                    try stmts.append(self.allocator, stmt);
                }
            } else {
                cond_sim.simulate(inst) catch return null;
            }
        }

        const expr = cond_sim.stack.popExpr() catch return null;
        const base_vals = try self.cloneStackValues(&cond_sim, cond_sim.stack.items.items);
        return .{ .expr = expr, .base_vals = base_vals };
    }

    fn makeBoolPair(
        self: *Decompiler,
        left: *Expr,
        right: *Expr,
        op: ast.BoolOp,
    ) DecompileError!*Expr {
        const a = self.arena.allocator();
        const values = try a.alloc(*Expr, 2);
        values[0] = left;
        values[1] = right;
        const bool_expr = try a.create(Expr);
        bool_expr.* = .{ .bool_op = .{
            .op = op,
            .values = values,
        } };
        return bool_expr;
    }

    fn condReach(
        self: *Decompiler,
        start: u32,
        target: u32,
        true_block: u32,
        false_block: u32,
    ) DecompileError!bool {
        if (start == target) return true;
        var seen = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer seen.deinit();

        var stack: std.ArrayListUnmanaged(u32) = .{};
        defer stack.deinit(self.allocator);

        try stack.append(self.allocator, start);
        while (stack.items.len > 0) {
            const cur = stack.items[stack.items.len - 1];
            stack.items.len -= 1;
            if (cur >= self.cfg.blocks.len) continue;
            if (seen.isSet(cur)) continue;
            seen.set(cur);

            const blk = &self.cfg.blocks[cur];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const next = edge.target;
                if (next == target) return true;
                if (next == true_block or next == false_block) continue;
                try stack.append(self.allocator, next);
            }
        }
        return false;
    }

    fn buildCondTree(
        self: *Decompiler,
        block_id: u32,
        first_block: u32,
        first_expr: *Expr,
        true_block: u32,
        false_block: u32,
        base_vals: []const StackValue,
        stop_false: ?u32,
        cond_kind: ?ctrl.BoolOpKind,
        in_stack: *std.DynamicBitSet,
        memo: *std.AutoHashMapUnmanaged(u32, *Expr),
    ) DecompileError!?*Expr {
        if (block_id >= self.cfg.blocks.len) return null;
        if (stop_false) |stop_id| {
            if (block_id == stop_id) return null;
        }
        if (memo.get(block_id)) |expr| return expr;
        if (in_stack.isSet(block_id)) return null;
        in_stack.set(block_id);
        defer in_stack.unset(block_id);

        const block = &self.cfg.blocks[block_id];
        const term = block.terminator() orelse return null;
        if (!ctrl.Analyzer.isConditionalJump(undefined, term.opcode)) return null;

        const expr = if (block_id == first_block)
            first_expr
        else blk: {
            if (cond_kind) |kind| {
                const skip = self.boolOpBlockSkip(block, kind);
                break :blk (try self.simulateBoolOpCondExpr(block_id, base_vals, skip, kind)) orelse return null;
            }
            break :blk (try self.simulateConditionExpr(block_id, base_vals)) orelse return null;
        };

        var true_id: ?u32 = null;
        var false_id: ?u32 = null;
        for (block.successors) |edge| {
            if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                true_id = edge.target;
            } else if (edge.edge_type == .conditional_false) {
                false_id = edge.target;
            }
        }
        if (true_id == null or false_id == null) return null;

        const t_id = true_id.?;
        const f_id = false_id.?;
        const t_is_false = t_id == false_block or (stop_false != null and t_id == stop_false.?);
        const f_is_false = f_id == false_block or (stop_false != null and f_id == stop_false.?);

        if (t_id == true_block and f_is_false) {
            try memo.put(self.allocator, block_id, expr);
            return expr;
        }

        if (t_is_false and f_is_false) return null;

        if (t_id == true_block) {
            const rhs = (try self.buildCondTree(
                f_id,
                first_block,
                first_expr,
                true_block,
                false_block,
                base_vals,
                stop_false,
                cond_kind,
                in_stack,
                memo,
            )) orelse return null;
            const out = try self.makeBoolPair(expr, rhs, .or_);
            try memo.put(self.allocator, block_id, out);
            return out;
        }
        if (f_is_false) {
            const rhs = (try self.buildCondTree(
                t_id,
                first_block,
                first_expr,
                true_block,
                false_block,
                base_vals,
                stop_false,
                cond_kind,
                in_stack,
                memo,
            )) orelse return null;
            const out = try self.makeBoolPair(expr, rhs, .and_);
            try memo.put(self.allocator, block_id, out);
            return out;
        }
        if (t_is_false) {
            const rhs = (try self.buildCondTree(
                f_id,
                first_block,
                first_expr,
                true_block,
                false_block,
                base_vals,
                stop_false,
                cond_kind,
                in_stack,
                memo,
            )) orelse return null;
            const not_expr = try ast.makeUnaryOp(self.arena.allocator(), .not_, expr);
            const out = try self.makeBoolPair(not_expr, rhs, .and_);
            try memo.put(self.allocator, block_id, out);
            return out;
        }

        const t_expr = (try self.buildCondTree(
            t_id,
            first_block,
            first_expr,
            true_block,
            false_block,
            base_vals,
            stop_false,
            cond_kind,
            in_stack,
            memo,
        )) orelse return null;
        const f_expr = (try self.buildCondTree(
            f_id,
            first_block,
            first_expr,
            true_block,
            false_block,
            base_vals,
            stop_false,
            cond_kind,
            in_stack,
            memo,
        )) orelse return null;

        if (try self.condReach(t_id, f_id, true_block, false_block)) {
            var t_stop_expr: ?*Expr = null;
            if (stop_false == null) {
                t_stop_expr = try self.buildCondTreeStopped(
                    t_id,
                    first_block,
                    first_expr,
                    true_block,
                    false_block,
                    base_vals,
                    f_id,
                    cond_kind,
                );
            }
            const t_use = t_stop_expr orelse t_expr;
            const left = try self.makeBoolPair(expr, t_use, .and_);
            const out = try self.makeBoolPair(left, f_expr, .or_);
            try memo.put(self.allocator, block_id, out);
            return out;
        }
        if (try self.condReach(f_id, t_id, true_block, false_block)) {
            var f_stop_expr: ?*Expr = null;
            if (stop_false == null) {
                f_stop_expr = try self.buildCondTreeStopped(
                    f_id,
                    first_block,
                    first_expr,
                    true_block,
                    false_block,
                    base_vals,
                    t_id,
                    cond_kind,
                );
            }
            const f_use = f_stop_expr orelse f_expr;
            const left = try self.makeBoolPair(expr, f_use, .or_);
            const out = try self.makeBoolPair(left, t_expr, .and_);
            try memo.put(self.allocator, block_id, out);
            return out;
        }

        const not_expr = try ast.makeUnaryOp(self.arena.allocator(), .not_, expr);
        const left = try self.makeBoolPair(expr, t_expr, .and_);
        const right = try self.makeBoolPair(not_expr, f_expr, .and_);
        const out = try self.makeBoolPair(left, right, .or_);
        try memo.put(self.allocator, block_id, out);
        return out;
    }

    fn buildCondTreeStopped(
        self: *Decompiler,
        block_id: u32,
        first_block: u32,
        first_expr: *Expr,
        true_block: u32,
        false_block: u32,
        base_vals: []const StackValue,
        stop_false: u32,
        cond_kind: ?ctrl.BoolOpKind,
    ) DecompileError!?*Expr {
        var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer in_stack.deinit();

        var memo: std.AutoHashMapUnmanaged(u32, *Expr) = .{};
        defer memo.deinit(self.allocator);

        return self.buildCondTree(
            block_id,
            first_block,
            first_expr,
            true_block,
            false_block,
            base_vals,
            stop_false,
            cond_kind,
            &in_stack,
            &memo,
        );
    }

    fn saveTernary(
        self: *Decompiler,
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

        self.pending_ternary_expr = if_expr;
        if (base_owned.*) {
            deinitStackValuesSlice(self.allocator, base_vals);
            base_owned.* = false;
        }
    }

    fn findTernaryLeaf(
        self: *Decompiler,
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

    fn tryDecompileTernaryTreeInto(
        self: *Decompiler,
        block_id: u32,
        limit: u32,
        stmts: *std.ArrayList(*Stmt),
    ) DecompileError!?u32 {
        const pattern = (try self.findTernaryLeaf(block_id, limit)) orelse return null;

        const cond_res = (try self.initCondSim(block_id, stmts)) orelse return null;
        const base_vals = cond_res.base_vals;
        var base_owned = true;
        defer if (base_owned) deinitStackValuesSlice(self.allocator, base_vals);

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
        )) orelse return null;

        const true_expr = (try self.simulateTernaryBranch(pattern.true_block, base_vals)) orelse return null;
        const false_expr = (try self.simulateTernaryBranch(pattern.false_block, base_vals)) orelse return null;

        try self.saveTernary(condition, true_expr, false_expr, base_vals, &base_owned);
        return pattern.merge_block;
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

            var base_vals: []StackValue = &.{};
            var base_owned = false;
            var true_expr: *Expr = undefined;
            var false_expr: *Expr = undefined;

            var cond_list: std.ArrayListUnmanaged(*Expr) = .{};
            defer cond_list.deinit(self.allocator);

            // Note: expressions are arena-allocated, so no explicit cleanup needed
            defer {
                if (base_owned) {
                    deinitStackValuesSlice(self.allocator, base_vals);
                }
            }

            const cond_res = (try self.initCondSim(chain.condition_blocks[0], stmts)) orelse return null;
            try cond_list.append(self.allocator, cond_res.expr);
            base_vals = cond_res.base_vals;
            base_owned = true;

            if (chain.condition_blocks.len > 1) {
                for (chain.condition_blocks[1..]) |cond_id| {
                    const cond_opt = try self.simulateConditionExpr(cond_id, base_vals);
                    if (cond_opt == null) return null;
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

            const true_opt = try self.simulateTernaryBranch(chain.true_block, base_vals);
            if (true_opt == null) return null;
            true_expr = true_opt.?;

            const false_opt = try self.simulateTernaryBranch(chain.false_block, base_vals);
            if (false_opt == null) return null;
            false_expr = false_opt.?;

            try self.saveTernary(condition, true_expr, false_expr, base_vals, &base_owned);
            return chain.merge_block;
        }

        if (try self.tryDecompileTernaryTreeInto(block_id, limit, stmts)) |next_block| {
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

        // Note: expressions are arena-allocated, so no explicit cleanup needed
        defer {
            if (base_owned) {
                deinitStackValuesSlice(self.allocator, base_vals);
            }
        }

        const cond_res = (try self.initCondSim(pattern.condition_block, stmts)) orelse return null;
        const condition = cond_res.expr;
        base_vals = cond_res.base_vals;
        base_owned = true;

        const true_opt = try self.simulateTernaryBranch(pattern.true_block, base_vals);
        if (true_opt == null) return null;
        true_expr = true_opt.?;

        const false_opt = try self.simulateTernaryBranch(pattern.false_block, base_vals);
        if (false_opt == null) return null;
        false_expr = false_opt.?;

        try self.saveTernary(condition, true_expr, false_expr, base_vals, &base_owned);
        return pattern.merge_block;
    }

    const InlineCompResult = struct {
        exit_block: u32,
        stack: []const StackValue,
    };

    fn tryDecompileInlineListComp(
        self: *Decompiler,
        pattern: ctrl.ForPattern,
    ) DecompileError!?InlineCompResult {
        const setup = &self.cfg.blocks[pattern.setup_block];
        const header = &self.cfg.blocks[pattern.header_block];
        var comp_start: ?u32 = null;
        var after_build = false;

        // Helper to check if opcode is a BUILD_* for comprehensions
        const isBuildComp = struct {
            fn check(op: Opcode, arg: u32) bool {
                return arg == 0 and (op == .BUILD_LIST or op == .BUILD_SET or op == .BUILD_MAP);
            }
        }.check;

        // Check setup block first (Python <3.12 pattern: BUILD_* before GET_ITER)
        for (setup.instructions) |inst| {
            if (isBuildComp(inst.opcode, inst.arg)) {
                comp_start = inst.offset;
                after_build = true;
                continue;
            }
            if (inst.opcode == .GET_ITER) break;
            if (after_build) {
                switch (inst.opcode) {
                    .STORE_NAME,
                    .STORE_GLOBAL,
                    .STORE_FAST,
                    .STORE_DEREF,
                    .POP_TOP,
                    => {
                        comp_start = null;
                        after_build = false;
                    },
                    else => {},
                }
            }
        }

        // Python 3.12+: BUILD_* is AFTER GET_ITER in setup block (before FOR_ITER)
        if (comp_start == null) {
            var past_get_iter = false;
            for (setup.instructions) |inst| {
                if (inst.opcode == .GET_ITER) {
                    past_get_iter = true;
                    continue;
                }
                if (!past_get_iter) continue;
                if (isBuildComp(inst.opcode, inst.arg)) {
                    comp_start = inst.offset;
                    break;
                }
            }
        }

        // Fallback: check header block for BUILD_* before FOR_ITER
        if (comp_start == null) {
            for (header.instructions) |inst| {
                if (isBuildComp(inst.opcode, inst.arg)) {
                    comp_start = inst.offset;
                    break;
                }
                if (inst.opcode == .FOR_ITER) break;
            }
        }

        const start = comp_start orelse return null;

        const term = header.terminator() orelse return null;
        if (term.opcode != .FOR_ITER) return null;
        const exit_offset = term.jumpTarget(self.version) orelse return null;
        if (exit_offset <= start) return null;

        // Find GET_ITER position
        var get_iter_offset: ?u32 = null;
        for (setup.instructions) |inst| {
            if (inst.opcode == .GET_ITER) {
                get_iter_offset = inst.offset;
                break;
            }
        }

        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        // Determine simulation start point based on pattern type
        var sim_start = start;

        // Python <3.12: BUILD_LIST comes before GET_ITER, simulate from BUILD_LIST
        // Python 3.12+: BUILD_LIST comes after GET_ITER, need to set up iterator first
        if (get_iter_offset) |gio| {
            if (start < gio) {
                // Python <3.12: BUILD_LIST before GET_ITER
                // Simulate from BUILD_LIST (start)
                sim_start = start;
            } else {
                // Python 3.12+: BUILD_LIST after GET_ITER
                // Simulate setup code to get iterator expression, then start from GET_ITER
                var setup_sim = SimContext.init(self.arena.allocator(), self.code, self.version);
                defer setup_sim.deinit();

                var setup_iter = decoder.InstructionIterator.init(self.code.code, self.version);
                while (setup_iter.next()) |inst| {
                    if (inst.offset >= gio) break;
                    if (inst.opcode == .RESUME) continue;
                    setup_sim.simulate(inst) catch continue;
                }

                // Get the iterator expression from TOS
                if (setup_sim.stack.pop()) |val| {
                    switch (val) {
                        .expr => |e| try sim.stack.push(.{ .expr = e }),
                        else => {
                            const iter_placeholder = try ast.makeName(self.arena.allocator(), ".iter", .load);
                            try sim.stack.push(.{ .expr = iter_placeholder });
                        },
                    }
                } else {
                    const iter_placeholder = try ast.makeName(self.arena.allocator(), ".iter", .load);
                    try sim.stack.push(.{ .expr = iter_placeholder });
                }
                sim_start = gio;
            }
        }

        var iter = decoder.InstructionIterator.init(self.code.code, self.version);
        while (iter.next()) |inst| {
            if (inst.offset < sim_start) continue;
            if (inst.offset >= exit_offset) break;
            try sim.simulate(inst);
        }

        const expr = sim.buildInlineCompExpr() catch |err| {
            if (err == error.InvalidComprehension) return null;
            return err;
        } orelse return null;

        if (self.pending_ternary_expr != null) return error.InvalidBlock;
        self.pending_ternary_expr = expr;

        const stack_copy = try self.allocator.dupe(StackValue, sim.stack.items.items);
        return .{ .exit_block = pattern.exit_block, .stack = stack_copy };
    }

    /// Try to decompile a try pattern as an inline comprehension.
    /// Python 3.12+ comprehensions have exception cleanup code that looks like try/except.
    fn tryDecompileTryAsComprehension(
        self: *Decompiler,
        pattern: ctrl.TryPattern,
        stmts: *std.ArrayList(*Stmt),
    ) DecompileError!?u32 {
        if (!self.version.gte(3, 12)) return null;
        if (pattern.handlers.len == 0) return null;

        const handler_id = pattern.handlers[0].handler_block;
        if (handler_id >= self.cfg.blocks.len) return null;
        const handler = &self.cfg.blocks[handler_id];

        // Check if this is comprehension cleanup: SWAP, POP_TOP, SWAP, STORE_FAST, RERAISE
        var has_reraise = false;
        for (handler.instructions) |inst| {
            if (inst.opcode == .RERAISE) {
                has_reraise = true;
                break;
            }
        }
        if (!has_reraise) return null;

        // Look for FOR_ITER in try body that has LIST_APPEND/SET_ADD/MAP_ADD
        const try_id = pattern.try_block;
        var for_block_id: ?u32 = null;
        var exit_block_id: ?u32 = null;

        var bid = try_id;
        var body_block_id: ?u32 = null;
        while (bid < handler_id) : (bid += 1) {
            const block = &self.cfg.blocks[bid];
            const term = block.terminator() orelse continue;
            if (term.opcode == .FOR_ITER) {
                // Get body and exit from successors
                var body_id_opt: ?u32 = null;
                var exit_id_opt: ?u32 = null;
                for (block.successors) |edge| {
                    if (edge.edge_type == .normal) {
                        body_id_opt = edge.target;
                    } else if (edge.edge_type == .conditional_false) {
                        exit_id_opt = edge.target;
                    }
                }
                const body_id = body_id_opt orelse continue;
                const exit_id = exit_id_opt orelse continue;

                // Check if body has LIST_APPEND/SET_ADD/MAP_ADD
                if (body_id < self.cfg.blocks.len) {
                    const body = &self.cfg.blocks[body_id];
                    for (body.instructions) |inst| {
                        if (inst.opcode == .LIST_APPEND or
                            inst.opcode == .SET_ADD or
                            inst.opcode == .MAP_ADD)
                        {
                            for_block_id = bid;
                            body_block_id = body_id;
                            exit_block_id = exit_id;
                            break;
                        }
                    }
                }
            }
            if (for_block_id != null) break;
        }

        if (for_block_id == null) return null;

        const for_pattern = ctrl.ForPattern{
            .setup_block = try_id,
            .header_block = for_block_id.?,
            .body_block = body_block_id.?,
            .exit_block = exit_block_id.?,
        };

        // Decompile blocks before the for loop
        if (for_block_id.? > try_id) {
            const pre_stmts = try self.decompileBlockRangeWithStack(try_id, for_block_id.?, &.{});
            defer self.allocator.free(pre_stmts);
            try stmts.appendSlice(self.allocator, pre_stmts);
        }

        // Try to decompile as inline comprehension
        if (try self.tryDecompileInlineListComp(for_pattern)) |result| {
            // Comprehension is now in pending_ternary_expr
            // Process the exit block to pick it up
            defer self.allocator.free(result.stack);
            const exit_id = exit_block_id.?;
            if (exit_id < self.cfg.blocks.len) {
                const exit_stmts = try self.decompileBlockRangeWithStack(exit_id, handler_id, result.stack);
                defer self.allocator.free(exit_stmts);
                try stmts.appendSlice(self.allocator, exit_stmts);
            }
            self.allocator.free(pattern.handlers);
            return handler_id + 1;
        }

        return null;
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
                try cond_sim.simulate(inst);
            }
        } else {
            // Simulate condition block up to conditional jump
            for (cond_block.instructions) |inst| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                if (isStatementOpcode(inst.opcode)) return null;
                try cond_sim.simulate(inst);
            }
        }

        // First operand is on stack
        const first = cond_sim.stack.popExpr() catch return null;
        errdefer {
            first.deinit(self.allocator);
            self.allocator.destroy(first);
        }

        const base_vals = try self.cloneStackValues(&cond_sim, cond_sim.stack.items.items);
        defer deinitStackValuesSlice(self.allocator, base_vals);

        // Build potentially nested BoolOp expression
        const bool_result = try self.buildBoolOpExpr(first, pattern, base_vals);
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
    fn buildBoolOpExpr(
        self: *Decompiler,
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
            const skip = self.boolOpBlockSkip(blk, pattern.kind);

            const term = blk.terminator();
            const is_cond = if (term) |t| ctrl.Analyzer.isConditionalJump(undefined, t.opcode) else false;
            if (!is_cond) {
                const expr = (try self.simulateValueExprSkip(cur_block, base_vals, skip)) orelse {
                    return error.InvalidBlock;
                };
                try values_list.append(self.allocator, expr);
                break;
            }

            const expr = (try self.simulateBoolOpCondExpr(cur_block, base_vals, skip, pattern.kind)) orelse {
                return error.InvalidBlock;
            };

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
                    const header = &self.cfg.blocks[p.header_block];
                    const term = header.terminator();
                    const legacy_cond = if (term) |t| t.opcode == .JUMP_IF_FALSE or t.opcode == .JUMP_IF_TRUE else false;
                    const exit_block = &self.cfg.blocks[p.exit_block];
                    if (legacy_cond and exit_block.instructions.len > 0 and exit_block.instructions[0].opcode == .POP_TOP) {
                        const exit_stmts = try self.decompileBlockRangeWithStackAndSkip(
                            p.exit_block,
                            p.exit_block + 1,
                            &.{},
                            1,
                        );
                        defer self.allocator.free(exit_stmts);
                        try self.statements.appendSlice(self.allocator, exit_stmts);
                        block_idx = p.exit_block + 1;
                    } else {
                        block_idx = p.exit_block;
                    }
                },
                .for_loop => |p| {
                    if (try self.tryDecompileInlineListComp(p)) |result| {
                        self.allocator.free(result.stack);
                        block_idx = result.exit_block;
                        continue;
                    }
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .try_stmt => |p| {
                    // Check for inline comprehension before try/except
                    if (try self.tryDecompileTryAsComprehension(p, &self.statements)) |next_block| {
                        block_idx = next_block;
                        continue;
                    }
                    if (try self.tryDecompileAsyncFor(p)) |result| {
                        if (result.stmt) |s| {
                            try self.statements.append(self.allocator, s);
                        }
                        block_idx = result.next_block;
                        continue;
                    }
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
        const limit = end_block orelse @as(u32, @intCast(self.cfg.blocks.len));
        if (start_block >= limit) return &[_]*Stmt{};

        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

        try self.decompileBlockIntoWithStackAndSkip(start_block, &stmts, init_stack, skip_first);

        if (start_block + 1 < limit) {
            const rest = try self.decompileStructuredRange(start_block + 1, limit);
            try stmts.appendSlice(a, rest);
        }

        return stmts.toOwnedSlice(a);
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

    /// Try to decompile assert pattern: if cond: pass else: raise AssertionError[(...)]
    fn tryDecompileAssert(
        self: *Decompiler,
        pattern: ctrl.IfPattern,
        cond: *Expr,
        else_block: u32,
        then_body: []const *Stmt,
        base_vals: []const StackValue,
        skip: usize,
    ) DecompileError!?*Stmt {
        _ = pattern;
        _ = base_vals;
        // Assert has empty then body and else raises AssertionError
        if (then_body.len != 0) return null;
        if (else_block >= self.cfg.blocks.len) return null;

        const block = &self.cfg.blocks[else_block];
        // Pattern: [NOT_TAKEN,] LOAD_COMMON_CONSTANT 0, [LOAD_CONST msg, CALL,] RAISE_VARARGS 1
        var i: usize = skip;
        while (i < block.instructions.len and block.instructions[i].opcode == .NOT_TAKEN) : (i += 1) {}
        if (i >= block.instructions.len) return null;

        // Check for LOAD_COMMON_CONSTANT 0 (AssertionError) or LOAD_ASSERTION_ERROR
        const load_inst = block.instructions[i];
        const is_assertion_error = (load_inst.opcode == .LOAD_COMMON_CONSTANT and load_inst.arg == 0) or
            load_inst.opcode == .LOAD_ASSERTION_ERROR;
        if (!is_assertion_error) return null;

        i += 1;
        if (i >= block.instructions.len) return null;

        // Check for optional message: LOAD_CONST followed by CALL
        var msg: ?*Expr = null;
        if (block.instructions[i].opcode == .LOAD_CONST) {
            const const_idx = block.instructions[i].arg;
            var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
            defer sim.deinit();
            if (sim.getConst(const_idx)) |obj| {
                msg = try sim.objToExpr(obj);
            }
            i += 1;
            if (i < block.instructions.len and block.instructions[i].opcode == .CALL) {
                i += 1;
            }
        }

        // Check for RAISE_VARARGS 1
        if (i >= block.instructions.len) return null;
        if (block.instructions[i].opcode != .RAISE_VARARGS or block.instructions[i].arg != 1) {
            if (msg) |m| {
                m.deinit(self.arena.allocator());
                self.arena.allocator().destroy(m);
            }
            return null;
        }

        // Create assert statement
        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .{ .assert_stmt = .{
            .condition = cond,
            .msg = msg,
        } };
        return stmt;
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
        const then_body_tmp = try self.decompileBranchRange(pattern.then_block, then_end, base_vals, skip);
        defer self.allocator.free(then_body_tmp);
        const a = self.arena.allocator();
        const then_body = try a.dupe(*Stmt, then_body_tmp);

        // Check for assert pattern: if cond: pass else: raise AssertionError
        if (pattern.else_block) |else_id| {
            if (try self.tryDecompileAssert(pattern, condition, else_id, then_body_tmp, base_vals, skip)) |assert_stmt| {
                for (base_vals) |val| val.deinit(self.allocator);
                self.allocator.free(base_vals);
                return assert_stmt;
            }
        }

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
            const else_body_tmp = try self.decompileBranchRange(else_id, pattern.merge_block, base_vals, skip);
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

    fn decompileBranchRange(
        self: *Decompiler,
        start_block: u32,
        end_block: ?u32,
        base_vals: []const StackValue,
        skip_first: usize,
    ) DecompileError![]const *Stmt {
        const limit = end_block orelse @as(u32, @intCast(self.cfg.blocks.len));
        if (start_block >= limit) return &[_]*Stmt{};

        if (skip_first > 0 or base_vals.len > 0) {
            var stmts: std.ArrayList(*Stmt) = .{};
            errdefer stmts.deinit(self.allocator);

            try self.decompileBlockIntoWithStackAndSkip(start_block, &stmts, base_vals, skip_first);

            if (start_block + 1 < limit) {
                const rest = try self.decompileStructuredRange(start_block + 1, limit);
                defer self.allocator.free(rest);
                try stmts.appendSlice(self.allocator, rest);
            }

            return stmts.toOwnedSlice(self.allocator);
        }

        return self.decompileStructuredRange(start_block, limit);
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
        const term = header.terminator();
        const legacy_cond = if (term) |t| t.opcode == .JUMP_IF_FALSE or t.opcode == .JUMP_IF_TRUE else false;
        const body_block = &self.cfg.blocks[pattern.body_block];
        var seed_pop = legacy_cond and body_block.instructions.len > 0 and body_block.instructions[0].opcode == .POP_TOP;
        const body = try self.decompileLoopBody(
            pattern.body_block,
            pattern.header_block,
            &skip_first,
            &seed_pop,
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

    fn tryDecompileAsyncFor(self: *Decompiler, pattern: ctrl.TryPattern) DecompileError!?PatternResult {
        if (self.version.lt(3, 5)) return null;
        if (pattern.handlers.len == 0) return null;

        var handled = false;
        defer if (handled) self.allocator.free(pattern.handlers);

        var handler_id: ?u32 = null;
        for (pattern.handlers) |handler_info| {
            if (handler_info.handler_block >= self.cfg.blocks.len) continue;
            const handler = &self.cfg.blocks[handler_info.handler_block];

            var has_stop = false;
            var has_cmp = false;
            var has_jump = false;
            for (handler.instructions) |inst| {
                switch (inst.opcode) {
                    .LOAD_GLOBAL => {
                        if (self.code.names.len > inst.arg) {
                            if (std.mem.eql(u8, self.code.names[inst.arg], "StopAsyncIteration")) {
                                has_stop = true;
                            }
                        }
                    },
                    .COMPARE_OP => {
                        if (inst.arg == 10) has_cmp = true;
                    },
                    .POP_JUMP_IF_TRUE, .POP_JUMP_IF_FALSE => has_jump = true,
                    else => {},
                }
            }
            if (has_stop and has_cmp and has_jump) {
                handler_id = handler_info.handler_block;
                break;
            }
        }
        if (handler_id == null) return null;

        const try_id = pattern.try_block;
        if (try_id >= self.cfg.blocks.len) return null;
        const try_block = &self.cfg.blocks[try_id];

        var setup_id: ?u32 = null;
        var setup_off: ?u32 = null;
        var aiter_id: ?u32 = null;
        const setup_scan = blk: {
            if (try_block.predecessors.len == 0) break :blk &[_]u32{try_id};
            const tmp = try self.allocator.alloc(u32, try_block.predecessors.len + 1);
            tmp[0] = try_id;
            @memcpy(tmp[1..], try_block.predecessors);
            break :blk tmp;
        };
        defer if (try_block.predecessors.len > 0) self.allocator.free(setup_scan);
        for (setup_scan) |block_id| {
            if (block_id >= self.cfg.blocks.len) continue;
            const block = &self.cfg.blocks[block_id];
            var has_aiter = false;
            var has_setup = false;
            var setup_offset: u32 = 0;
            for (block.instructions) |inst| {
                if (inst.opcode == .GET_AITER) has_aiter = true;
                if (inst.opcode == .SETUP_EXCEPT) {
                    has_setup = true;
                    setup_offset = inst.offset;
                }
            }
            if (!has_setup) continue;
            if (has_aiter) {
                setup_id = block_id;
                setup_off = setup_offset;
                aiter_id = block_id;
                break;
            }
            for (block.predecessors) |pred_id| {
                if (pred_id >= self.cfg.blocks.len) continue;
                const pred = &self.cfg.blocks[pred_id];
                for (pred.instructions) |inst| {
                    if (inst.opcode == .GET_AITER) {
                        setup_id = block_id;
                        setup_off = setup_offset;
                        aiter_id = pred_id;
                        break;
                    }
                }
                if (aiter_id != null) break;
            }
            if (setup_id != null) break;
        }
        const setup_block_id = setup_id orelse return null;
        const setup_block = &self.cfg.blocks[setup_block_id];
        const setup_except_off = setup_off orelse return null;
        const aiter_block_id = aiter_id orelse setup_block_id;
        const aiter_block = &self.cfg.blocks[aiter_block_id];

        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        for (aiter_block.instructions) |inst| {
            if (inst.opcode == .GET_AITER) break;
            try sim.simulate(inst);
        }
        const iter_expr = sim.stack.popExpr() catch return null;

        const a = self.arena.allocator();
        var target: *Expr = undefined;
        var found_target = false;
        var saw_yield = false;
        var idx: usize = 0;
        while (idx < try_block.instructions.len) : (idx += 1) {
            const inst = try_block.instructions[idx];
            if (inst.opcode == .YIELD_FROM) {
                saw_yield = true;
                continue;
            }
            if (!saw_yield) continue;
            switch (inst.opcode) {
                .UNPACK_SEQUENCE => {
                    const count = inst.arg;
                    if (count == 0) {
                        target = try a.create(Expr);
                        target.* = .{ .tuple = .{ .elts = &.{}, .ctx = .store } };
                        found_target = true;
                        break;
                    }
                    if (idx + count >= try_block.instructions.len) return null;
                    const elts = try a.alloc(*Expr, count);
                    var j: u32 = 0;
                    while (j < count) : (j += 1) {
                        const store_inst = try_block.instructions[idx + 1 + j];
                        const name = switch (store_inst.opcode) {
                            .STORE_FAST => sim.getLocal(store_inst.arg) orelse "_",
                            .STORE_DEREF => sim.getDeref(store_inst.arg) orelse "_",
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(store_inst.arg) orelse "_",
                            else => return null,
                        };
                        const name_expr = try a.create(Expr);
                        name_expr.* = .{ .name = .{ .id = name, .ctx = .store } };
                        elts[j] = name_expr;
                    }
                    target = try a.create(Expr);
                    target.* = .{ .tuple = .{ .elts = elts, .ctx = .store } };
                    found_target = true;
                    break;
                },
                .STORE_FAST => {
                    const name = sim.getLocal(inst.arg) orelse "_";
                    target = try ast.makeName(a, name, .store);
                    found_target = true;
                    break;
                },
                .STORE_DEREF => {
                    const name = sim.getDeref(inst.arg) orelse "_";
                    target = try ast.makeName(a, name, .store);
                    found_target = true;
                    break;
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    const name = sim.getName(inst.arg) orelse "_";
                    target = try ast.makeName(a, name, .store);
                    found_target = true;
                    break;
                },
                else => {},
            }
            if (found_target) break;
        }
        if (!found_target) return null;

        var body_start_off: ?u32 = null;
        var body_empty = false;
        var found_pop = false;
        var next_after_pop: ?decoder.Instruction = null;
        var pop_block = try_block;
        var pop_idx: usize = 0;
        for (try_block.instructions, 0..) |inst, i| {
            if (inst.opcode != .POP_BLOCK) continue;
            found_pop = true;
            pop_idx = i;
            break;
        }
        if (!found_pop) {
            for (try_block.successors) |edge| {
                if (edge.edge_type != .normal) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                const succ = &self.cfg.blocks[edge.target];
                for (succ.instructions, 0..) |inst, i| {
                    if (inst.opcode != .POP_BLOCK) continue;
                    found_pop = true;
                    pop_block = succ;
                    pop_idx = i;
                    break;
                }
                if (found_pop) break;
            }
        }
        if (!found_pop) return null;
        if (pop_idx + 1 < pop_block.instructions.len) {
            next_after_pop = pop_block.instructions[pop_idx + 1];
        } else if (pop_block.end_offset < self.code.code.len) {
            if (self.cfg.blockAtOffset(pop_block.end_offset)) |next_id| {
                const next_block = &self.cfg.blocks[next_id];
                if (next_block.instructions.len > 0) {
                    next_after_pop = next_block.instructions[0];
                }
            }
        }
        if (next_after_pop) |next_inst| {
            switch (next_inst.opcode) {
                .JUMP_FORWARD,
                .JUMP_ABSOLUTE,
                .JUMP_BACKWARD,
                .JUMP_BACKWARD_NO_INTERRUPT,
                => {
                    const target_off = next_inst.jumpTarget(self.version) orelse return null;
                    if (target_off == setup_except_off and next_inst.opcode != .JUMP_FORWARD) {
                        body_empty = true;
                    } else {
                        body_start_off = target_off;
                    }
                },
                else => {
                    body_start_off = next_inst.offset;
                },
            }
        }

        var loop_end_off: ?u32 = null;
        // Search setup block and predecessors for SETUP_LOOP
        const search_blocks = blk: {
            if (setup_block.predecessors.len == 0) break :blk &[_]u32{setup_block_id};
            const tmp = try self.allocator.alloc(u32, setup_block.predecessors.len + 1);
            tmp[0] = setup_block_id;
            @memcpy(tmp[1..], setup_block.predecessors);
            break :blk tmp;
        };
        defer if (setup_block.predecessors.len > 0) self.allocator.free(search_blocks);
        for (search_blocks) |bid| {
            if (bid >= self.cfg.blocks.len) continue;
            const blk = &self.cfg.blocks[bid];
            for (blk.instructions) |inst| {
                if (inst.opcode == .SETUP_LOOP) {
                    const multiplier: u32 = if (self.version.gte(3, 10)) 2 else 1;
                    loop_end_off = inst.offset + inst.size + inst.arg * multiplier;
                    break;
                }
            }
            if (loop_end_off != null) break;
        }
        const exit_off = loop_end_off orelse return null;
        const exit_ptr = self.cfg.blockContaining(exit_off) orelse return null;
        const exit_block = exit_ptr.id;

        var body: []const *Stmt = &.{};
        if (!body_empty) {
            const body_off = body_start_off orelse return null;
            const body_block = self.cfg.blockAtOffset(body_off) orelse return null;
            body = try self.decompileStructuredRange(body_block, exit_block);
        }

        const stmt = try a.create(Stmt);
        stmt.* = .{ .for_stmt = .{
            .target = target,
            .iter = iter_expr,
            .body = body,
            .else_body = &.{},
            .type_comment = null,
            .is_async = true,
        } };

        handled = true;
        return .{ .stmt = stmt, .next_block = exit_block };
    }

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

        std.mem.sort(u32, handler_blocks.items, {}, std.sort.asc(u32));

        if (self.version.gte(3, 11)) {
            return try self.decompileTry311(pattern, handler_blocks.items);
        }

        var handler_set = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer handler_set.deinit();
        for (handler_blocks.items) |hid| {
            handler_set.set(hid);
        }

        var protected_set = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer protected_set.deinit();
        for (self.cfg.blocks, 0..) |block, i| {
            for (block.successors) |edge| {
                if (edge.edge_type == .exception and handler_set.isSet(edge.target)) {
                    protected_set.set(i);
                    break;
                }
            }
        }

        var post_try_entry: ?u32 = null;
        for (self.cfg.blocks, 0..) |block, i| {
            if (!protected_set.isSet(i)) continue;
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (protected_set.isSet(edge.target)) continue;
                if (handler_set.isSet(edge.target)) continue;
                post_try_entry = if (post_try_entry) |prev|
                    @min(prev, edge.target)
                else
                    edge.target;
            }
        }

        var handler_reach = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer handler_reach.deinit();
        for (handler_blocks.items) |hid| {
            var reach = try self.collectReachableNoException(hid, &handler_set);
            defer reach.deinit();
            handler_reach.setUnion(reach);
        }

        var join_block: ?u32 = null;
        if (post_try_entry) |entry| {
            var normal_reach = try self.collectReachableNoException(entry, &handler_set);
            defer normal_reach.deinit();
            var it = normal_reach.iterator(.{});
            while (it.next()) |bit| {
                if (handler_reach.isSet(bit)) {
                    join_block = @intCast(bit);
                    break;
                }
            }
        }

        var has_finally = false;
        for (handler_blocks.items) |hid| {
            if (self.isFinallyHandler(hid)) {
                has_finally = true;
                break;
            }
        }

        var else_start: ?u32 = null;
        if (post_try_entry) |entry| {
            if (!handler_reach.isSet(entry)) {
                if (join_block == null or entry != join_block.?) {
                    else_start = entry;
                }
            }
        }

        var finally_start: ?u32 = null;
        if (has_finally) {
            finally_start = join_block orelse post_try_entry;
        }

        const handler_start = handler_blocks.items[0];
        var try_end: u32 = handler_start;
        if (else_start) |start| {
            if (start < try_end) try_end = start;
        }
        if (finally_start) |start| {
            if (start < try_end) try_end = start;
        }

        const try_body = if (pattern.try_block < try_end)
            try self.decompileTryBody(pattern.try_block, try_end)
        else
            &[_]*Stmt{};

        var else_end: u32 = handler_start;
        if (else_start) |start| {
            if (finally_start) |final_start| {
                if (final_start > start and final_start < else_end) else_end = final_start;
            }
            if (join_block) |join| {
                if (join > start and join < else_end) else_end = join;
            }
        }

        const else_body = if (else_start) |start| blk: {
            if (start >= else_end) break :blk &[_]*Stmt{};
            break :blk try self.decompileStructuredRange(start, else_end);
        } else &[_]*Stmt{};

        var final_end: u32 = pattern.exit_block orelse @as(u32, @intCast(self.cfg.blocks.len));
        if (finally_start) |final_start| {
            if (handler_start > final_start and handler_start < final_end) {
                final_end = handler_start;
            }
        }

        const final_body = if (finally_start) |start| blk: {
            if (start >= final_end) break :blk &[_]*Stmt{};
            break :blk try self.decompileStructuredRange(start, final_end);
        } else &[_]*Stmt{};

        const a = self.arena.allocator();
        var handler_nodes = try a.alloc(ast.ExceptHandler, handler_blocks.items.len);
        var handler_count: usize = 0;
        errdefer {
            for (handler_nodes[0..handler_count]) |*h| {
                if (h.type) |t| {
                    t.deinit(a);
                    a.destroy(t);
                }
                if (h.body.len > 0) a.free(h.body);
            }
            a.free(handler_nodes);
        }

        for (handler_blocks.items, 0..) |hid, idx| {
            const handler_end = blk: {
                const next_handler = if (idx + 1 < handler_blocks.items.len)
                    handler_blocks.items[idx + 1]
                else
                    (pattern.exit_block orelse @as(u32, @intCast(self.cfg.blocks.len)));
                if (finally_start) |start| {
                    if (start > hid and start < next_handler) break :blk start;
                }
                break :blk next_handler;
            };

            const info = try self.extractHandlerHeader(hid);
            const body = try self.decompileHandlerBody(info.body_block, handler_end, info.skip_first_store, info.skip);
            handler_nodes[idx] = .{
                .type = info.exc_type,
                .name = info.name,
                .body = body,
            };
            handler_count = idx + 1;
        }

        const stmt = try a.create(Stmt);
        stmt.* = .{
            .try_stmt = .{
                .body = try_body,
                .handlers = handler_nodes,
                .else_body = else_body,
                .finalbody = final_body,
            },
        };

        var next_block: u32 = final_end;
        if (next_block < try_end) next_block = try_end;
        if (else_start) |start| {
            if (start > next_block) next_block = start;
        }
        if (pattern.exit_block) |exit| {
            if (exit > next_block) next_block = exit;
        }

        const last_handler = handler_blocks.items[handler_blocks.items.len - 1];
        if (next_block <= last_handler) {
            next_block = last_handler + 1;
        }

        return .{ .stmt = stmt, .next_block = next_block };
    }

    fn decompileWith(self: *Decompiler, pattern: ctrl.WithPattern) DecompileError!PatternResult {
        const setup = &self.cfg.blocks[pattern.setup_block];
        var sim = SimContext.init(self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        var is_async = false;
        var optional_vars: ?*Expr = null;
        var context_expr: ?*Expr = null;

        // Python 3.14+ uses LOAD_SPECIAL for with statement setup
        // Pattern: CALL (context manager) -> COPY -> LOAD_SPECIAL...
        // We need to capture the context expression before COPY or LOAD_SPECIAL
        for (setup.instructions) |inst| {
            switch (inst.opcode) {
                .BEFORE_ASYNC_WITH => is_async = true,
                else => {},
            }

            // Capture context expression right before COPY or LOAD_SPECIAL (clone, don't pop)
            if ((inst.opcode == .COPY or inst.opcode == .LOAD_SPECIAL) and context_expr == null) {
                if (sim.stack.items.items.len > 0) {
                    const top = sim.stack.items.items[sim.stack.items.items.len - 1];
                    if (top == .expr) {
                        context_expr = try ast.cloneExpr(self.arena.allocator(), top.expr);
                    }
                }
            }

            // Stop at LOAD_SPECIAL - rest is just method binding
            if (inst.opcode == .LOAD_SPECIAL or inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH) {
                break;
            }

            try sim.simulate(inst);
        }

        // In Python 3.14+, the variable binding (STORE_NAME) is in the body block
        // Check first instruction of body block for the binding
        if (pattern.body_block < self.cfg.blocks.len) {
            const body = &self.cfg.blocks[pattern.body_block];
            if (body.instructions.len > 0) {
                const first = body.instructions[0];
                switch (first.opcode) {
                    .STORE_FAST => {
                        if (sim.getLocal(first.arg)) |name| {
                            optional_vars = try ast.makeName(self.allocator, name, .store);
                        }
                    },
                    .STORE_NAME, .STORE_GLOBAL => {
                        if (sim.getName(first.arg)) |name| {
                            optional_vars = try ast.makeName(self.allocator, name, .store);
                        }
                    },
                    else => {},
                }
            }
        }

        const ctx_expr = context_expr orelse try sim.stack.popExpr();

        const item = try self.allocator.alloc(ast.WithItem, 1);
        item[0] = .{
            .context_expr = ctx_expr,
            .optional_vars = optional_vars,
        };

        // Skip the first instruction of body if it's the STORE for the "as" variable
        var skip_body_first: u32 = 0;
        if (optional_vars != null and pattern.body_block < self.cfg.blocks.len) {
            const body_blk = &self.cfg.blocks[pattern.body_block];
            if (body_blk.instructions.len > 0) {
                const first = body_blk.instructions[0];
                if (first.opcode == .STORE_FAST or first.opcode == .STORE_NAME or first.opcode == .STORE_GLOBAL) {
                    skip_body_first = 1;
                }
            }
        }

        // Decompile body directly without pattern detection
        // The body block may be detected as TRY (due to exception handling for with),
        // but it's not a user-written try/except - it's the with statement body
        var body_stmts: std.ArrayList(*Stmt) = .{};
        errdefer body_stmts.deinit(self.allocator);

        if (pattern.body_block < self.cfg.blocks.len) {
            const body_blk = &self.cfg.blocks[pattern.body_block];
            // Skip the STORE instruction for the "as" variable
            const skip_count: u32 = if (optional_vars != null) 1 else 0;
            try self.decompileBlockIntoWithStackAndSkip(pattern.body_block, &body_stmts, &.{}, skip_count);
            // Mark body block as processed so it's not reprocessed
            _ = body_blk;
        }

        const body = try body_stmts.toOwnedSlice(self.allocator);

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

        // Calculate exit block - skip past all with-related blocks
        // For a with statement, we need to skip: setup, body, normal cleanup, and exception handlers
        var exit = pattern.exit_block;
        // Make sure we skip past body and cleanup blocks
        if (pattern.body_block >= exit) exit = pattern.body_block + 1;
        if (pattern.cleanup_block >= exit) exit = pattern.cleanup_block + 1;
        // Find the highest exception handler block and skip past it
        if (pattern.cleanup_block < self.cfg.blocks.len) {
            const cleanup_blk = &self.cfg.blocks[pattern.cleanup_block];
            for (cleanup_blk.successors) |edge| {
                if (edge.target >= exit) exit = edge.target + 1;
            }
        }

        return .{ .stmt = stmt, .next_block = exit };
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
                    if (try self.tryDecompileInlineListComp(p)) |result| {
                        self.allocator.free(result.stack);
                        block_idx = result.exit_block;
                        continue;
                    }
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .try_stmt => |p| {
                    if (try self.tryDecompileAsyncFor(p)) |result| {
                        if (result.stmt) |s| {
                            try stmts.append(self.allocator, s);
                        }
                        block_idx = result.next_block;
                        continue;
                    }
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

    /// Decompile try/except for Python 3.11+
    fn decompileTry311(
        self: *Decompiler,
        pattern: ctrl.TryPattern,
        handler_ids: []const u32,
    ) DecompileError!PatternResult {
        const a = self.arena.allocator();

        // Find first handler block
        if (handler_ids.len == 0) {
            return .{ .stmt = null, .next_block = pattern.try_block + 1 };
        }

        const first_handler = handler_ids[0];
        const max_handler = handler_ids[handler_ids.len - 1];

        // Decompile try body (blocks from try_block to first handler, or to else block)
        const try_end = pattern.else_block orelse first_handler;
        const try_body = try self.decompileBlockRangeWithStack(
            pattern.try_block,
            try_end,
            &.{},
        );

        // Decompile handlers - follow the chain of CHECK_EXC_MATCH blocks
        var handlers: std.ArrayList(ast.ExceptHandler) = .{};
        errdefer handlers.deinit(a);

        // Track actual end of all handler blocks for marking processed
        var actual_end: u32 = max_handler + 1;

        // Start with first handler block (has PUSH_EXC_INFO)
        var current_handler: ?u32 = first_handler;

        while (current_handler) |hid| {
            if (hid >= self.cfg.blocks.len) break;
            const handler_block = &self.cfg.blocks[hid];

            // Check if this is a valid handler block or finally block
            var has_push_exc = false;
            var has_check_match = false;
            var has_reraise = false;
            var has_pop_top = false;
            var has_pop_except = false;
            for (handler_block.instructions) |inst| {
                if (inst.opcode == .PUSH_EXC_INFO) has_push_exc = true;
                if (inst.opcode == .CHECK_EXC_MATCH) has_check_match = true;
                if (inst.opcode == .RERAISE) has_reraise = true;
                if (inst.opcode == .POP_TOP) has_pop_top = true;
                if (inst.opcode == .POP_EXCEPT) has_pop_except = true;
            }
            // Stop if we hit a RERAISE-only block (cleanup, not handler)
            if (!has_push_exc and !has_check_match and has_reraise) break;

            // Check for finally pattern: PUSH_EXC_INFO + RERAISE without POP_EXCEPT
            // Finally handlers re-raise after cleanup, except handlers use POP_EXCEPT
            if (has_push_exc and has_reraise and !has_pop_except and !has_check_match) {
                // This is a finally block - extract finally body from handler
                // The finally code is between PUSH_EXC_INFO and RERAISE
                var finally_start: usize = 0;
                var finally_end: usize = handler_block.instructions.len;
                for (handler_block.instructions, 0..) |inst, i| {
                    if (inst.opcode == .PUSH_EXC_INFO) {
                        finally_start = i + 1;
                    } else if (inst.opcode == .RERAISE) {
                        finally_end = i;
                        break;
                    }
                }
                // Decompile finally body from the handler block
                const finally_body = try self.decompileBlockRangeWithStackAndSkip(
                    hid,
                    hid + 1,
                    &.{},
                    finally_start,
                );
                // Build try/finally statement (no handlers)
                const try_stmt = try a.create(Stmt);
                try_stmt.* = .{
                    .try_stmt = .{
                        .body = try_body,
                        .handlers = &.{},
                        .else_body = &.{},
                        .finalbody = finally_body,
                    },
                };
                self.analyzer.markProcessed(pattern.try_block, hid + 2);
                return .{ .stmt = try_stmt, .next_block = hid + 2 };
            }

            // Skip if block has neither handler pattern
            if (!has_push_exc and !has_check_match and !has_pop_top) break;

            // Extract exception type and name from handler header
            // Python 3.11+ handler patterns:
            // - Bare except: PUSH_EXC_INFO, POP_TOP, <body>, POP_EXCEPT
            // - except Type: PUSH_EXC_INFO, <load type>, CHECK_EXC_MATCH, POP_JUMP_IF_FALSE, POP_TOP, <body>
            // - except Type as e: PUSH_EXC_INFO, <load type>, CHECK_EXC_MATCH, POP_JUMP_IF_FALSE, STORE_*, <body>
            var exc_type: ?*Expr = null;
            var exc_name: ?[]const u8 = null;
            var body_skip: usize = 0;

            var sim = SimContext.init(a, self.code, self.version);
            defer sim.deinit();

            var seen_push_exc = false;
            var seen_check_match = false;
            var seen_cond_jump = false;

            for (handler_block.instructions, 0..) |inst, i| {
                switch (inst.opcode) {
                    .PUSH_EXC_INFO => {
                        seen_push_exc = true;
                        body_skip = i + 1;
                    },
                    .NOT_TAKEN => {
                        // NOT_TAKEN is just a marker, skip and continue
                        body_skip = i + 1;
                    },
                    .POP_TOP => {
                        if (seen_push_exc and !seen_check_match) {
                            // Bare except (first handler) - POP_TOP discards exception
                            body_skip = i + 1;
                            break;
                        } else if (!seen_push_exc and !seen_check_match and i == 0) {
                            // Bare except (chained) - POP_TOP at start of block
                            body_skip = i + 1;
                            break;
                        } else if (seen_cond_jump) {
                            // After conditional jump in typed except - pops exception value
                            body_skip = i + 1;
                            break;
                        }
                        body_skip = i + 1;
                    },
                    .CHECK_EXC_MATCH => {
                        // Exception type is on stack BEFORE this instruction consumes it
                        seen_check_match = true;
                        if (sim.stack.peek()) |val| {
                            switch (val) {
                                .expr => |e| exc_type = e,
                                else => {},
                            }
                        }
                        // Don't pop - let simulation handle it (it pushes bool)
                        body_skip = i + 1;
                    },
                    .POP_JUMP_IF_FALSE, .POP_JUMP_IF_TRUE => {
                        seen_cond_jump = true;
                        body_skip = i + 1;
                    },
                    .STORE_NAME, .STORE_FAST, .STORE_GLOBAL => {
                        if (seen_cond_jump) {
                            // This is "except Type as name:" - store the exception name
                            exc_name = switch (inst.opcode) {
                                .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg),
                                .STORE_FAST => sim.getLocal(inst.arg),
                                else => null,
                            };
                            body_skip = i + 1;
                            break;
                        }
                        // Otherwise it's part of body
                        break;
                    },
                    else => {
                        sim.simulate(inst) catch {};
                    },
                }
            }

            // For typed except, body is in fall-through successor after cond jump
            // Also track next handler (conditional_false = exception didn't match)
            var body_block = hid;
            var next_handler_block: ?u32 = null;
            if (seen_check_match and seen_cond_jump) {
                // Body is NOT_TAKEN path (conditional_true = exception matched)
                // Next handler is conditional_false path (exception didn't match)
                for (handler_block.successors) |edge| {
                    if (edge.edge_type == .conditional_true) {
                        body_block = edge.target;
                        body_skip = 0;
                    } else if (edge.edge_type == .conditional_false) {
                        next_handler_block = edge.target;
                    }
                }
                // Check body block for "as name:" binding (NOT_TAKEN, STORE_NAME pattern)
                // Note: NOT_TAKEN, POP_TOP, or STORE_NAME may be in next block if CFG split them
                var check_block = body_block;
                while (check_block < self.cfg.blocks.len and check_block < body_block + 2) {
                    const check_blk = &self.cfg.blocks[check_block];
                    for (check_blk.instructions, 0..) |inst, i| {
                        const is_first_block = (check_block == body_block);
                        if (inst.opcode == .NOT_TAKEN) {
                            if (is_first_block) body_skip = i + 1;
                        } else if (inst.opcode == .STORE_NAME or inst.opcode == .STORE_FAST or inst.opcode == .STORE_GLOBAL) {
                            // "except Type as name:" - extract name
                            exc_name = switch (inst.opcode) {
                                .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg),
                                .STORE_FAST => sim.getLocal(inst.arg),
                                else => null,
                            };
                            if (is_first_block) {
                                body_skip = i + 1;
                            } else {
                                // Binding is in next block, skip entire first block
                                body_skip = check_blk.instructions.len;
                                body_block = check_block;
                                body_skip = 1;
                            }
                            check_block = @intCast(self.cfg.blocks.len); // Break outer loop
                            break;
                        } else if (inst.opcode == .POP_TOP) {
                            // "except Type:" without name binding
                            if (is_first_block) {
                                body_skip = i + 1;
                            } else {
                                // POP_TOP is in next block, skip it
                                body_block = check_block;
                                body_skip = 1;
                            }
                            check_block = @intCast(self.cfg.blocks.len); // Break outer loop
                            break;
                        } else {
                            check_block = @intCast(self.cfg.blocks.len); // Break outer loop
                            break;
                        }
                    }
                    check_block += 1;
                }
            }

            // Find body end by scanning forward for POP_EXCEPT
            var handler_end_block = body_block + 1;
            var scan_block = body_block;
            while (scan_block < self.cfg.blocks.len) {
                const scan_blk = &self.cfg.blocks[scan_block];
                var found_pop_except = false;
                for (scan_blk.instructions) |inst| {
                    if (inst.opcode == .POP_EXCEPT) {
                        found_pop_except = true;
                        break;
                    }
                }
                if (found_pop_except) {
                    handler_end_block = scan_block + 1;
                    break;
                }
                scan_block += 1;
                if (scan_block > body_block + 10) break; // Safety limit
            }

            // Decompile handler body
            const handler_body = try self.decompileBlockRangeWithStackAndSkip(
                body_block,
                handler_end_block,
                &.{},
                body_skip,
            );

            try handlers.append(a, .{
                .type = exc_type,
                .name = exc_name,
                .body = handler_body,
            });

            // Track the actual end of processed blocks
            if (handler_end_block > actual_end) actual_end = handler_end_block;
            if (body_block >= actual_end) actual_end = body_block + 1;

            // Follow chain to next handler (if any)
            // next_handler_block points to RERAISE or another handler block
            current_handler = null;
            if (next_handler_block) |next_blk| {
                if (next_blk < self.cfg.blocks.len) {
                    const next_block = &self.cfg.blocks[next_blk];
                    // Check if this is another handler (has CHECK_EXC_MATCH or starts with POP_TOP for bare except)
                    var is_handler = false;
                    for (next_block.instructions) |inst| {
                        if (inst.opcode == .CHECK_EXC_MATCH) {
                            is_handler = true;
                            break;
                        }
                        if (inst.opcode == .RERAISE) {
                            // This is the end of handlers
                            break;
                        }
                    }
                    // Also check for bare except (POP_TOP followed by handler body)
                    if (!is_handler and next_block.instructions.len > 0) {
                        const first_op = next_block.instructions[0].opcode;
                        if (first_op == .POP_TOP) {
                            // This is a bare except handler
                            is_handler = true;
                        }
                    }
                    if (is_handler) {
                        current_handler = next_blk;
                    }
                    if (next_blk >= actual_end) actual_end = next_blk + 1;
                }
            }
        }

        if (handlers.items.len == 0) {
            // No real handlers, skip
            return .{ .stmt = null, .next_block = max_handler + 1 };
        }

        // Decompile else block if present
        var else_body: []const *Stmt = &.{};
        if (pattern.else_block) |else_start| {
            // Else block runs from else_start to first handler
            else_body = try self.decompileBlockRangeWithStack(
                else_start,
                first_handler,
                &.{},
            );
            if (else_start >= actual_end) actual_end = else_start + 1;
        }

        // Mark all processed blocks to prevent re-detection
        self.analyzer.markProcessed(pattern.try_block, actual_end);

        // Build try statement
        const try_stmt = try a.create(Stmt);
        try_stmt.* = .{
            .try_stmt = .{
                .body = try_body,
                .handlers = try handlers.toOwnedSlice(a),
                .else_body = else_body,
                .finalbody = &.{},
            },
        };

        return .{ .stmt = try_stmt, .next_block = actual_end };
    }

    fn decompileTryBody(self: *Decompiler, start: u32, end: u32) DecompileError![]const *Stmt {
        if (start >= end or start >= self.cfg.blocks.len) return &[_]*Stmt{};

        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

        var skip_store = false;
        var seed_pop = false;
        try self.processBlockStatements(
            start,
            &self.cfg.blocks[start],
            &stmts,
            &skip_store,
            &seed_pop,
            true,
            null,
        );

        const next = start + 1;
        if (next < end and next < self.cfg.blocks.len) {
            const rest = try self.decompileStructuredRange(next, end);
            try stmts.appendSlice(a, rest);
        }

        return stmts.toOwnedSlice(a);
    }

    const HandlerHeader = struct {
        exc_type: ?*Expr,
        name: ?[]const u8,
        skip_first_store: bool,
        body_block: u32,
        skip: usize,
    };

    fn extractHandlerHeader(self: *Decompiler, handler_block: u32) DecompileError!HandlerHeader {
        if (handler_block >= self.cfg.blocks.len) return error.InvalidBlock;
        const block = &self.cfg.blocks[handler_block];
        const a = self.arena.allocator();
        var sim = SimContext.init(a, self.code, self.version);
        defer sim.deinit();

        var exc_type: ?*Expr = null;
        var name: ?[]const u8 = null;
        var skip_first_store = false;
        var body_block: u32 = handler_block;
        var skip: usize = 0;

        var has_dup = false;
        var has_exc_cmp = false;
        var has_jump = false;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .DUP_TOP => has_dup = true,
                .COMPARE_OP => {
                    if (inst.arg == 10) has_exc_cmp = true;
                },
                .JUMP_IF_FALSE, .POP_JUMP_IF_FALSE, .JUMP_IF_TRUE, .POP_JUMP_IF_TRUE => has_jump = true,
                else => {},
            }
        }
        const legacy = has_dup and has_exc_cmp and has_jump;

        if (legacy) {
            for (block.successors) |edge| {
                if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                    body_block = edge.target;
                    break;
                }
            }

            for (block.instructions) |inst| {
                if (inst.opcode == .COMPARE_OP and inst.arg == 10) {
                    // Pop the exception type - we're taking ownership
                    if (sim.stack.pop()) |val| {
                        switch (val) {
                            .expr => |e| exc_type = e,
                            else => {
                                var v = val;
                                v.deinit(a);
                            },
                        }
                    }
                    break;
                }
                if (inst.opcode == .DUP_TOP and sim.stack.len() == 0) {
                    const dummy = try a.create(Expr);
                    dummy.* = .{ .name = .{ .id = "<exc>", .ctx = .load } };
                    try sim.stack.push(.{ .expr = dummy });
                }
                try sim.simulate(inst);
            }

            if (body_block < self.cfg.blocks.len) {
                const body = &self.cfg.blocks[body_block];
                var idx: usize = 0;
                var saw_pop = false;
                while (idx < body.instructions.len) {
                    const inst = body.instructions[idx];
                    switch (inst.opcode) {
                        .POP_TOP => {
                            saw_pop = true;
                            idx += 1;
                            continue;
                        },
                        .STORE_FAST => if (saw_pop and name == null) {
                            name = sim.getLocal(inst.arg);
                            idx += 1;
                            continue;
                        },
                        .STORE_NAME, .STORE_GLOBAL => if (saw_pop and name == null) {
                            name = sim.getName(inst.arg);
                            idx += 1;
                            continue;
                        },
                        .STORE_DEREF => if (saw_pop and name == null) {
                            name = sim.getDeref(inst.arg);
                            idx += 1;
                            continue;
                        },
                        else => {},
                    }
                    break;
                }
                skip = idx;
            }
        } else {
            for (block.instructions) |inst| {
                if (inst.opcode == .CHECK_EXC_MATCH) {
                    exc_type = try sim.stack.popExpr();
                    break;
                }
                try sim.simulate(inst);
            }

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
                    .STORE_DEREF => {
                        name = sim.getDeref(inst.arg);
                        break;
                    },
                    else => {},
                }
            }
            skip_first_store = name != null;
        }

        return .{
            .exc_type = exc_type,
            .name = name,
            .skip_first_store = skip_first_store,
            .body_block = body_block,
            .skip = skip,
        };
    }

    fn decompileHandlerBody(
        self: *Decompiler,
        start: u32,
        end: u32,
        skip_first_store: bool,
        skip: usize,
    ) DecompileError![]const *Stmt {
        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

        if (start >= end or start >= self.cfg.blocks.len) {
            return &[_]*Stmt{};
        }

        var skip_store = skip_first_store;
        var seed_pop = false;
        var head = self.cfg.blocks[start];
        if (skip > 0 and skip < head.instructions.len) {
            head.instructions = head.instructions[skip..];
        }

        try self.processBlockStatements(
            start,
            &head,
            &stmts,
            &skip_store,
            &seed_pop,
            false,
            null,
        );

        if (start + 1 < end) {
            const rest = try self.decompileStructuredRange(start + 1, end);
            try stmts.appendSlice(a, rest);
        }

        return stmts.toOwnedSlice(a);
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
            if (inst.opcode == .COMPARE_OP and inst.arg == 10) return false;
        }
        for (block.instructions) |inst| {
            if (inst.opcode == .RERAISE or inst.opcode == .END_FINALLY) return true;
        }
        return false;
    }

    fn hasExceptionHandlerOpcodes(self: *Decompiler, block: *const BasicBlock) bool {
        _ = self;
        var has_dup = false;
        var has_exc_cmp = false;
        var has_jump = false;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .PUSH_EXC_INFO, .CHECK_EXC_MATCH, .POP_EXCEPT => return true,
                .DUP_TOP => has_dup = true,
                .COMPARE_OP => {
                    if (inst.arg == 10) has_exc_cmp = true;
                },
                .JUMP_IF_FALSE, .POP_JUMP_IF_FALSE => has_jump = true,
                else => {},
            }
        }
        return has_dup and has_exc_cmp and has_jump;
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
        var seed_pop = false;
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
                .for_loop => |p| {
                    if (try self.tryDecompileInlineListComp(p)) |result| {
                        self.allocator.free(result.stack);
                        block_idx = result.exit_block;
                        continue;
                    }
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = p.exit_block;
                    continue;
                },
                .while_loop => |p| {
                    const stmt = try self.decompileWhile(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = p.exit_block;
                    continue;
                },
                .try_stmt => |p| {
                    if (try self.tryDecompileAsyncFor(p)) |result| {
                        if (result.stmt) |s| {
                            try stmts.append(a, s);
                        }
                        block_idx = result.next_block;
                        continue;
                    }
                    const result = try self.decompileTry(p);
                    if (result.stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = result.next_block;
                    continue;
                },
                .with_stmt => |p| {
                    const result = try self.decompileWith(p);
                    if (result.stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = result.next_block;
                    continue;
                },
                .match_stmt => |p| {
                    const result = try self.decompileMatch(p);
                    if (result.stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = result.next_block;
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
                        &seed_pop,
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
        seed_pop: *bool,
        stop_at_jump: bool,
        loop_header: ?u32,
    ) DecompileError!void {
        const a = self.arena.allocator();
        var sim = SimContext.init(a, self.code, self.version);
        defer sim.deinit();

        if (skip_first_store.*) {
            // Loop target consumes the iteration value from the stack.
            try sim.stack.push(.unknown);
        }
        if (seed_pop.*) {
            // Legacy JUMP_IF_* leaves the condition on stack for a leading POP_TOP.
            try sim.stack.push(.unknown);
            seed_pop.* = false;
        }
        if (self.pending_ternary_expr) |expr| {
            try sim.stack.push(.{ .expr = expr });
            self.pending_ternary_expr = null;
        }

        var skip_store_count: u32 = 0;

        for (block.instructions) |inst| {
            errdefer if (self.last_error_ctx == null) {
                self.last_error_ctx = .{
                    .code_name = self.code.name,
                    .block_id = block_id,
                    .offset = inst.offset,
                    .opcode = inst.opcode.name(),
                };
            };
            switch (inst.opcode) {
                .UNPACK_SEQUENCE => {
                    const count = inst.arg;
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        if (count == 0) {
                            // Empty unpack as for loop target - just consume the value
                            _ = sim.stack.pop();
                            continue;
                        }
                        skip_store_count = count;
                        try sim.simulate(inst);
                        continue;
                    }
                    // Look ahead for unpacking assignment pattern
                    const seq_expr = sim.stack.popExpr() catch {
                        try sim.simulate(inst);
                        continue;
                    };
                    var targets: std.ArrayList([]const u8) = .{};
                    defer targets.deinit(a);
                    var found_all = true;
                    var j: usize = 0;
                    for (block.instructions) |check_inst| {
                        if (check_inst.offset <= inst.offset) continue;
                        if (j >= count) break;
                        const name: ?[]const u8 = switch (check_inst.opcode) {
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(check_inst.arg),
                            .STORE_FAST => sim.getLocal(check_inst.arg),
                            .STORE_DEREF => sim.getDeref(check_inst.arg),
                            else => null,
                        };
                        if (name) |n| {
                            try targets.append(a, n);
                            j += 1;
                        } else {
                            found_all = false;
                            break;
                        }
                    }
                    if (found_all and targets.items.len == count) {
                        const stmt = try self.makeUnpackAssign(targets.items, seq_expr);
                        try stmts.append(a, stmt);
                        skip_store_count = count;
                        // Push unknowns so skipped STORE_* have values to pop
                        var k: u32 = 0;
                        while (k < count) : (k += 1) {
                            try sim.stack.push(.unknown);
                        }
                    } else {
                        // Fallback: push expression back and simulate
                        try sim.stack.push(.{ .expr = seq_expr });
                        try sim.simulate(inst);
                    }
                },
                .STORE_FAST, .STORE_NAME, .STORE_GLOBAL, .STORE_DEREF => {
                    if (skip_store_count > 0) {
                        skip_store_count -= 1;
                        const val = sim.stack.pop() orelse return error.StackUnderflow;
                        val.deinit(self.allocator);
                        continue;
                    }
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        const val = sim.stack.pop() orelse return error.StackUnderflow;
                        val.deinit(self.allocator);
                        continue;
                    }
                    const name = switch (inst.opcode) {
                        .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                        .STORE_DEREF => sim.getDeref(inst.arg) orelse "<unknown>",
                        else => sim.getName(inst.arg) orelse "<unknown>",
                    };
                    const value = sim.stack.pop() orelse return error.StackUnderflow;
                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(a, stmt);
                    }
                },
                .STORE_SUBSCR => {
                    // STORE_SUBSCR: TOS1[TOS] = TOS2
                    // Arena allocator handles cleanup, no errdefer needed
                    const key = try sim.stack.popExpr();
                    const container = try sim.stack.popExpr();
                    const annotation = try sim.stack.popExpr();

                    // Check for variable annotation pattern: __annotations__['varname'] = type
                    if (container.* == .name and std.mem.eql(u8, container.name.id, "__annotations__") and
                        key.* == .constant and key.constant == .string)
                    {
                        const var_name = key.constant.string;
                        const target = try ast.makeName(a, var_name, .store);

                        // Check if previous statement was an assignment to the same variable
                        // Pattern: x = value; __annotations__['x'] = type => x: type = value
                        var assign_value: ?*Expr = null;
                        if (stmts.items.len > 0) {
                            const prev = stmts.items[stmts.items.len - 1];
                            if (prev.* == .assign and prev.assign.targets.len == 1) {
                                const prev_target = prev.assign.targets[0];
                                if (prev_target.* == .name and std.mem.eql(u8, prev_target.name.id, var_name)) {
                                    assign_value = prev.assign.value;
                                    // Remove the previous assignment
                                    _ = stmts.pop();
                                }
                            }
                        }

                        const stmt = try a.create(Stmt);
                        stmt.* = .{ .ann_assign = .{
                            .target = target,
                            .annotation = annotation,
                            .value = assign_value,
                            .simple = true,
                        } };
                        try stmts.append(a, stmt);
                    } else {
                        const subscript = try a.create(Expr);
                        subscript.* = .{ .subscript = .{
                            .value = container,
                            .slice = key,
                            .ctx = .store,
                        } };
                        const stmt = try self.makeAssign(subscript, annotation);
                        try stmts.append(a, stmt);
                    }
                },
                .STORE_SLICE => {
                    // STORE_SLICE (3.12+): TOS3[TOS2:TOS1] = TOS
                    // Arena allocator handles cleanup, no errdefer needed
                    const stop = try sim.stack.popExpr();
                    const start = try sim.stack.popExpr();
                    const container = try sim.stack.popExpr();
                    const value = try sim.stack.popExpr();

                    const slice_expr = try a.create(Expr);
                    const lower = if (start.* == .constant and start.constant == .none) null else start;
                    const upper = if (stop.* == .constant and stop.constant == .none) null else stop;
                    slice_expr.* = .{ .slice = .{ .lower = lower, .upper = upper, .step = null } };

                    const subscript = try a.create(Expr);
                    subscript.* = .{ .subscript = .{
                        .value = container,
                        .slice = slice_expr,
                        .ctx = .store,
                    } };
                    const stmt = try self.makeAssign(subscript, value);
                    try stmts.append(a, stmt);
                },
                .JUMP_FORWARD, .JUMP_BACKWARD, .JUMP_BACKWARD_NO_INTERRUPT, .JUMP_ABSOLUTE => {
                    // When stop_at_jump is true, we're at the natural end of a loop body.
                    // The terminating back-edge is NOT a continue statement - it's implicit.
                    // Only emit break/continue for jumps that are NOT the natural terminator.
                    if (stop_at_jump) return;
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
                },
                .RETURN_VALUE => {
                    const value = try sim.stack.popExpr();
                    // Skip 'return None' at module level (implicit return)
                    if (self.isModuleLevel() and value.* == .constant and value.constant == .none) {
                        continue;
                    }
                    const stmt = try self.makeReturn(value);
                    try stmts.append(a, stmt);
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const value = try sim.objToExpr(obj);
                        // Skip 'return None' at module level (implicit return)
                        if (self.isModuleLevel() and value.* == .constant and value.constant == .none) {
                            continue;
                        }
                        const stmt = try self.makeReturn(value);
                        try stmts.append(a, stmt);
                    }
                },
                .POP_TOP => {
                    if (sim.stack.len() == 0) {
                        if (self.allowsEmptyPop(block)) continue;
                        return error.StackUnderflow;
                    }
                    const val = sim.stack.pop().?;
                    switch (val) {
                        .expr => |expr| {
                            const stmt = try self.makeExprStmt(expr);
                            try stmts.append(a, stmt);
                        },
                        else => {
                            // Discard non-expression values (e.g., condition cleanup).
                            val.deinit(self.allocator);
                        },
                    }
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

    fn allowsEmptyPop(self: *Decompiler, block: *const cfg_mod.BasicBlock) bool {
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .END_FINALLY, .POP_EXCEPT, .RERAISE, .END_FOR => return true,
                else => {},
            }
        }
        if (block.instructions.len > 0 and block.instructions[0].opcode == .POP_TOP) {
            for (block.predecessors) |pred_id| {
                if (pred_id >= self.cfg.blocks.len) continue;
                const pred = &self.cfg.blocks[pred_id];
                const term = pred.terminator() orelse continue;
                if (term.opcode == .JUMP_IF_FALSE or term.opcode == .JUMP_IF_TRUE) return true;
            }
        }
        // Check if predecessor is a for loop header (FOR_ITER terminator)
        for (block.predecessors) |pred_id| {
            if (pred_id >= self.cfg.blocks.len) continue;
            const pred = &self.cfg.blocks[pred_id];
            const term = pred.terminator() orelse continue;
            if (term.opcode == .FOR_ITER) return true;
        }
        return false;
    }

    /// Decompile an if statement that's inside a loop.
    fn decompileLoopIf(
        self: *Decompiler,
        pattern: ctrl.IfPattern,
        loop_header: u32,
        visited: *std.DynamicBitSet,
    ) DecompileError!?*Stmt {
        const cond_block = &self.cfg.blocks[pattern.condition_block];
        const term = cond_block.terminator();
        const legacy_cond = if (term) |t| t.opcode == .JUMP_IF_FALSE or t.opcode == .JUMP_IF_TRUE else false;

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
        const then_block = &self.cfg.blocks[pattern.then_block];
        var seed_then = legacy_cond and then_block.instructions.len > 0 and then_block.instructions[0].opcode == .POP_TOP;
        const then_body = try self.decompileLoopBody(
            pattern.then_block,
            loop_header,
            &skip_first,
            &seed_then,
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
            const else_block = &self.cfg.blocks[else_id];
            var seed_else = legacy_cond and else_block.instructions.len > 0 and else_block.instructions[0].opcode == .POP_TOP;
            break :blk try self.decompileLoopBody(
                else_id,
                loop_header,
                &skip,
                &seed_else,
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
        seed_pop: *bool,
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
                        seed_pop,
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

        _ = nested_ptr.decompile() catch |err| {
            if (nested_ptr.last_error_ctx) |ctx| {
                self.last_error_ctx = ctx;
            }
            return err;
        };

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

        // Generate global/nonlocal declarations
        var decls: std.ArrayListUnmanaged(*Stmt) = .{};
        defer decls.deinit(a);

        // Nonlocal: variables in freevars
        if (func.code.freevars.len > 0) {
            const names = try a.alloc([]const u8, func.code.freevars.len);
            for (func.code.freevars, 0..) |fv, i| {
                names[i] = try a.dupe(u8, fv);
            }
            const nl_stmt = try a.create(Stmt);
            nl_stmt.* = .{ .nonlocal_stmt = .{ .names = names } };
            try decls.append(a, nl_stmt);
        }

        // Global: scan bytecode for STORE_GLOBAL/LOAD_GLOBAL
        var globals: std.StringHashMapUnmanaged(void) = .{};
        defer globals.deinit(a);
        var iter = decoder.InstructionIterator.init(func.code.code, self.version);
        while (iter.next()) |inst| {
            if (inst.opcode == .STORE_GLOBAL or inst.opcode == .LOAD_GLOBAL) {
                if (inst.arg < func.code.names.len) {
                    try globals.put(a, func.code.names[inst.arg], {});
                }
            }
        }
        if (globals.count() > 0) {
            const names = try a.alloc([]const u8, globals.count());
            var it = globals.keyIterator();
            var i: usize = 0;
            while (it.next()) |key| : (i += 1) {
                names[i] = try a.dupe(u8, key.*);
            }
            const g_stmt = try a.create(Stmt);
            g_stmt.* = .{ .global_stmt = .{ .names = names } };
            try decls.append(a, g_stmt);
        }

        // Prepend declarations to body
        if (decls.items.len > 0) {
            const new_body = try a.alloc(*Stmt, body.len + decls.items.len);
            @memcpy(new_body[0..decls.items.len], decls.items);
            @memcpy(new_body[decls.items.len..], body);
            body = new_body;
        }

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

    const SubscriptTargetResult = struct {
        target: *Expr,
        next_idx: usize,
    };

    /// Try to parse a subscript or attribute target from instruction stream.
    /// Pattern: LOAD container, (LOAD key | LOAD_CONST key), STORE_SUBSCR
    /// Or: LOAD container, STORE_ATTR
    fn tryParseSubscriptTarget(
        self: *Decompiler,
        sim: *SimContext,
        instructions: []const decoder.Instruction,
        start_idx: usize,
        arena: Allocator,
    ) DecompileError!?SubscriptTargetResult {
        _ = self;
        if (start_idx >= instructions.len) return null;

        // Simulate loads to build container expression
        var idx = start_idx;
        const container_inst = instructions[idx];

        // Get container name
        const container_name: ?[]const u8 = switch (container_inst.opcode) {
            .LOAD_NAME, .LOAD_GLOBAL => sim.getName(container_inst.arg),
            .LOAD_FAST => sim.getLocal(container_inst.arg),
            .LOAD_DEREF => sim.getDeref(container_inst.arg),
            else => null,
        };
        if (container_name == null) return null;

        const container = try ast.makeName(arena, container_name.?, .load);
        idx += 1;

        if (idx >= instructions.len) return null;
        const next = instructions[idx];

        // Check for STORE_ATTR (container.attr)
        if (next.opcode == .STORE_ATTR) {
            const attr_name = sim.getName(next.arg) orelse return null;
            const target = try arena.create(Expr);
            target.* = .{ .attribute = .{
                .value = container,
                .attr = attr_name,
                .ctx = .store,
            } };
            return .{ .target = target, .next_idx = idx + 1 };
        }

        // Check for BUILD_SLICE pattern: LOAD start, LOAD stop, [LOAD step], BUILD_SLICE, STORE_SUBSCR
        // Or simple key: LOAD key, STORE_SUBSCR
        const key_or_start: ?*Expr = try parseLoadExpr(sim, arena, next);
        if (key_or_start == null) return null;
        idx += 1;

        if (idx >= instructions.len) return null;

        // Check if this is a simple subscript (STORE_SUBSCR immediately follows)
        if (instructions[idx].opcode == .STORE_SUBSCR) {
            const target = try arena.create(Expr);
            target.* = .{ .subscript = .{
                .value = container,
                .slice = key_or_start.?,
                .ctx = .store,
            } };
            return .{ .target = target, .next_idx = idx + 1 };
        }

        // Check for slice pattern: start is loaded, now check for stop [and step]
        // Pattern: LOAD stop, [LOAD step], BUILD_SLICE n, STORE_SUBSCR
        const stop_inst = instructions[idx];
        const stop: ?*Expr = try parseLoadExpr(sim, arena, stop_inst);
        if (stop == null) return null;
        idx += 1;

        if (idx >= instructions.len) return null;

        var step: ?*Expr = null;
        var slice_arg: u32 = 2; // Default: 2 args (start, stop)

        // Check for step or BUILD_SLICE
        const maybe_step_or_build = instructions[idx];
        if (maybe_step_or_build.opcode == .BUILD_SLICE) {
            slice_arg = maybe_step_or_build.arg;
            idx += 1;
        } else {
            // Try to parse step
            step = try parseLoadExpr(sim, arena, maybe_step_or_build);
            if (step != null) {
                idx += 1;
                if (idx >= instructions.len) return null;
                if (instructions[idx].opcode != .BUILD_SLICE) return null;
                slice_arg = instructions[idx].arg;
                idx += 1;
            } else {
                return null;
            }
        }

        if (idx >= instructions.len) return null;
        if (instructions[idx].opcode != .STORE_SUBSCR) return null;

        // Build slice expression
        const slice_expr = try arena.create(Expr);
        const lower = if (key_or_start.?.* == .constant and key_or_start.?.constant == .none) null else key_or_start;
        const upper = if (stop.?.* == .constant and stop.?.constant == .none) null else stop;
        const step_val = if (step) |s| (if (s.* == .constant and s.constant == .none) null else s) else null;
        slice_expr.* = .{ .slice = .{ .lower = lower, .upper = upper, .step = step_val } };

        const target = try arena.create(Expr);
        target.* = .{ .subscript = .{
            .value = container,
            .slice = slice_expr,
            .ctx = .store,
        } };
        return .{ .target = target, .next_idx = idx + 1 };
    }

    /// Helper to parse a LOAD instruction into an expression
    fn parseLoadExpr(sim: *SimContext, arena: Allocator, inst: decoder.Instruction) DecompileError!?*Expr {
        return switch (inst.opcode) {
            .LOAD_NAME, .LOAD_GLOBAL => blk: {
                const name = sim.getName(inst.arg) orelse break :blk null;
                break :blk try ast.makeName(arena, name, .load);
            },
            .LOAD_FAST => blk: {
                const name = sim.getLocal(inst.arg) orelse break :blk null;
                break :blk try ast.makeName(arena, name, .load);
            },
            .LOAD_CONST => blk: {
                const c = sim.getConst(inst.arg) orelse break :blk null;
                break :blk try sim.objToExpr(c);
            },
            .LOAD_SMALL_INT => blk: {
                const val = @as(i64, @intCast(inst.arg));
                break :blk try ast.makeConstant(arena, .{ .int = val });
            },
            else => null,
        };
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

    /// Create unpacking assignment from expr targets: (self.a, b[0]) = expr
    fn makeUnpackAssignExprs(self: *Decompiler, target_exprs: []*Expr, value: *Expr) DecompileError!*Stmt {
        const a = self.arena.allocator();

        const tuple_expr = try a.create(Expr);
        tuple_expr.* = .{ .tuple = .{
            .elts = try a.dupe(*Expr, target_exprs),
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

    /// Check if this is module-level code.
    fn isModuleLevel(self: *const Decompiler) bool {
        return std.mem.eql(u8, self.code.name, "<module>");
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
                } else {
                    var buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Error: {s}\n", .{@errorName(err)}) catch "Error\n";
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
