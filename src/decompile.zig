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
const name_mangle = @import("name_mangle.zig");
const signature = @import("signature.zig");
const test_utils = @import("test_utils.zig");

pub const CFG = cfg_mod.CFG;
pub const BasicBlock = cfg_mod.BasicBlock;
pub const Analyzer = ctrl.Analyzer;
pub const SimContext = stack_mod.SimContext;
pub const Version = decoder.Version;
pub const Expr = ast.Expr;
pub const Stmt = ast.Stmt;
const ExprContext = ast.ExprContext;
const StackValue = stack_mod.StackValue;
const Opcode = decoder.Opcode;
pub const DecompileError = stack_mod.SimError || std.fs.File.WriteError || std.Io.Writer.Error || std.json.Stringify.Error || error{
    UnexpectedEmptyWorklist,
    InvalidBlock,
    SkipStatement,
};

fn isSoftSimErr(err: anyerror) bool {
    return switch (err) {
        error.StackUnderflow,
        error.NotAnExpression,
        error.InvalidSwapArg,
        error.InvalidDupArg,
        error.InvalidComprehension,
        error.InvalidConstant,
        error.InvalidLambdaBody,
        error.InvalidKeywordNames,
        error.InvalidStackDepth,
        error.UnsupportedConstant,
        error.InvalidConstKeyMap,
        => true,
        else => false,
    };
}

fn simOpt(sim: *SimContext, inst: decoder.Instruction) DecompileError!bool {
    sim.simulate(inst) catch |err| {
        if (isSoftSimErr(err)) return false;
        return err;
    };
    return true;
}

fn popExprOpt(sim: *SimContext) DecompileError!?*Expr {
    return sim.stack.popExpr() catch |err| {
        if (isSoftSimErr(err)) return null;
        return err;
    };
}

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

pub const DecompileOptions = struct {
    focus: ?[]const u8 = null,
    trace_loop_guards: bool = false,
    trace_sim_block: ?u32 = null,
    trace_decisions: bool = false,
    trace_file: ?std.fs.File = null,
};

const TraceStackVal = struct {
    tag: []const u8,
    text: ?[]const u8 = null,
};

const GuardTrace = struct {
    kind: []const u8,
    block: u32,
    header: u32,
    term_op: []const u8,
    target: u32,
    continues_path: []const u32,
    stack_in: []const TraceStackVal,
    guard_expr: []const u8,
    insert_idx: usize,
};

const SimTrace = struct {
    kind: []const u8,
    block: u32,
    offset: u32,
    op: []const u8,
    arg: u32,
    stack_before: []const TraceStackVal,
    stack_after: []const TraceStackVal,
};

const DecisionTrace = struct {
    kind: []const u8,
    block: u32,
    note: []const u8,
    cond: ?[]const u8 = null,
};

const GuardBranch = struct {
    target: u32,
    taken: bool,
    path: []const u32,
};

const GenSet = struct {
    marks: []u32,
    gen: u32,
    list: std.ArrayListUnmanaged(u32),

    fn init(allocator: Allocator, bit_len: usize) !GenSet {
        const marks = try allocator.alloc(u32, bit_len);
        @memset(marks, 0);
        var list: std.ArrayListUnmanaged(u32) = .{};
        if (bit_len > 0) {
            try list.ensureTotalCapacity(allocator, bit_len);
        }
        return .{ .marks = marks, .gen = 1, .list = list };
    }

    fn ensureSize(self: *GenSet, allocator: Allocator, bit_len: usize) !void {
        if (self.marks.len != bit_len) {
            const old_len = self.marks.len;
            self.marks = try allocator.realloc(self.marks, bit_len);
            if (bit_len > old_len) {
                @memset(self.marks[old_len..], 0);
            }
        }
        if (bit_len > self.list.capacity) {
            try self.list.ensureTotalCapacity(allocator, bit_len);
        }
        self.reset();
    }

    fn reset(self: *GenSet) void {
        self.gen +%= 1;
        if (self.gen == 0) {
            @memset(self.marks, 0);
            self.gen = 1;
        }
        self.list.clearRetainingCapacity();
    }

    fn set(self: *GenSet, allocator: Allocator, idx: u32) !void {
        const i: usize = @intCast(idx);
        if (i >= self.marks.len) return;
        if (self.marks[i] != self.gen) {
            self.marks[i] = self.gen;
            try self.list.append(allocator, idx);
        }
    }

    fn isSet(self: *const GenSet, idx: u32) bool {
        const i: usize = @intCast(idx);
        if (i >= self.marks.len) return false;
        return self.marks[i] == self.gen;
    }

    fn unset(self: *GenSet, idx: u32) void {
        const i: usize = @intCast(idx);
        if (i >= self.marks.len) return;
        if (self.marks[i] == self.gen) {
            self.marks[i] = 0;
        }
    }

    fn deinit(self: *GenSet, allocator: Allocator) void {
        if (self.marks.len > 0) allocator.free(self.marks);
        self.list.deinit(allocator);
    }
};

/// Decompiler state for a single code object.
pub const Decompiler = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    code: *const pyc.Code,
    version: Version,
    cfg: *CFG,
    analyzer: Analyzer,
    dom: *dom_mod.DomTree,
    postdom_idom: ?[]u32 = null,

    /// Accumulated statements.
    statements: std.ArrayList(*Stmt),
    /// Nested decompilers (kept alive for arena lifetime).
    nested_decompilers: std.ArrayList(*Decompiler),
    /// Next block after chained comparison (set by tryDecompileChainedComparison).
    chained_cmp_next_block: ?u32 = null,
    /// Pending ternary expression to be consumed by next STORE instruction.
    pending_ternary_expr: ?*Expr = null,
    /// Pending expression for next STORE (boolop merge with conditional).
    pending_store_expr: ?*Expr = null,
    /// Pending stack values to prepend before next pending expr.
    pending_vals: ?[]StackValue = null,
    /// Accumulated print items for Python 2.x PRINT_ITEM/PRINT_NEWLINE.
    print_items: std.ArrayList(*Expr),
    /// Print destination for PRINT_ITEM_TO.
    print_dest: ?*Expr = null,
    /// Error context for debugging.
    last_error_ctx: ?ErrorContext = null,
    /// Pending chain targets from STORE_ATTR before UNPACK_SEQUENCE.
    pending_chain_targets: std.ArrayList(*Expr),
    /// Saw __classcell__ store in class body; suppress return emission.
    saw_classcell: bool = false,
    /// Class name for name-unmangling in class scope (null outside classes).
    class_name: ?[]const u8 = null,
    /// Entry stack state per block (computed by dataflow).
    stack_in: []?[]StackValue,
    /// Guard against recursive if/elif cycles.
    if_in_progress: ?std.DynamicBitSet = null,
    /// Guard against recursive structured range cycles.
    range_in_progress: std.AutoHashMap(u64, void),
    /// Guard against recursive loop decompilation cycles.
    loop_in_progress: ?std.DynamicBitSet = null,
    /// Defensive recursion depth for loop decompilation.
    loop_depth: u32 = 0,
    /// Scratch buffers for try/except analysis.
    try_scratch: ?TryScratch = null,
    /// Scratch reachability set for conditional analysis.
    cond_seen: GenSet,
    /// Scratch DFS stack for conditional reachability.
    cond_stack: std.ArrayListUnmanaged(u32),
    /// Blocks already emitted into statements.
    consumed: GenSet,
    /// Scratch simulator for stack cloning.
    clone_sim: SimContext,
    /// Override for fallthrough after single-branch if.
    if_next: ?u32 = null,
    /// Override for next block after loop when folding exit guards.
    loop_next: ?u32 = null,
    /// Optional limit for branchEnd traversal.
    br_limit: ?u32 = null,
    /// Trace loop guard insertion.
    trace_loop_guards: bool = false,
    /// Trace stack simulation for a block.
    trace_sim_block: ?u32 = null,
    /// Trace control-flow rewrite decisions.
    trace_decisions: bool = false,
    /// Trace output file.
    trace_file: ?std.fs.File = null,

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

        const dom = try allocator.create(dom_mod.DomTree);
        errdefer allocator.destroy(dom);
        dom.* = try dom_mod.DomTree.init(allocator, cfg);
        errdefer dom.deinit();

        var analyzer = try Analyzer.init(allocator, cfg, dom);
        errdefer analyzer.deinit();

        var cond_seen = try GenSet.init(allocator, cfg.blocks.len);
        errdefer cond_seen.deinit(allocator);
        var consumed = try GenSet.init(allocator, cfg.blocks.len);
        errdefer consumed.deinit(allocator);
        var cond_stack: std.ArrayListUnmanaged(u32) = .{};
        errdefer cond_stack.deinit(allocator);
        if (cfg.blocks.len > 0) {
            try cond_stack.ensureTotalCapacity(allocator, cfg.blocks.len);
        }

        var decomp = Decompiler{
            .allocator = allocator,
            .arena = arena,
            .code = code,
            .version = version,
            .cfg = cfg,
            .analyzer = analyzer,
            .dom = dom,
            .postdom_idom = null,
            .statements = .{},
            .nested_decompilers = .{},
            .print_items = .{},
            .pending_chain_targets = .{},
            .stack_in = &.{},
            .range_in_progress = std.AutoHashMap(u64, void).init(allocator),
            .cond_seen = cond_seen,
            .cond_stack = cond_stack,
            .consumed = consumed,
            .clone_sim = SimContext.init(allocator, allocator, code, version),
            .class_name = null,
            .trace_loop_guards = false,
            .trace_sim_block = null,
            .trace_decisions = false,
            .trace_file = null,
        };

        try decomp.initStackFlow();
        decomp.if_in_progress = try std.DynamicBitSet.initEmpty(allocator, cfg.blocks.len);
        decomp.loop_in_progress = try std.DynamicBitSet.initEmpty(allocator, cfg.blocks.len);
        return decomp;
    }

    pub fn deinit(self: *Decompiler) void {
        self.clone_sim.deinit();
        for (self.nested_decompilers.items) |nested| {
            nested.deinit();
            self.allocator.destroy(nested);
        }
        self.nested_decompilers.deinit(self.allocator);
        self.print_items.deinit(self.allocator);
        self.pending_chain_targets.deinit(self.allocator);
        if (self.pending_vals) |vals| {
            deinitStackValuesSlice(self.allocator, self.allocator, vals);
            self.pending_vals = null;
        }
        for (self.stack_in) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.len > 0) self.allocator.free(entry);
            }
        }
        if (self.stack_in.len > 0) self.allocator.free(self.stack_in);
        if (self.if_in_progress) |*set| set.deinit();
        if (self.loop_in_progress) |*set| set.deinit();
        self.range_in_progress.deinit();
        self.analyzer.deinit();
        self.dom.deinit();
        self.allocator.destroy(self.dom);
        if (self.postdom_idom) |idom| {
            self.allocator.free(idom);
        }
        if (self.try_scratch) |*scratch| {
            scratch.deinit(self.allocator);
        }
        self.cond_seen.deinit(self.allocator);
        self.cond_stack.deinit(self.allocator);
        self.consumed.deinit(self.allocator);
        self.arena.deinit();
        self.statements.deinit(self.allocator);
    }

    const TryScratch = struct {
        handler_set: GenSet,
        protected_set: GenSet,
        handler_reach: GenSet,
        normal_reach: GenSet,
        queue: std.ArrayListUnmanaged(u32),

        fn init(allocator: Allocator, bit_len: usize) !TryScratch {
            return .{
                .handler_set = try GenSet.init(allocator, bit_len),
                .protected_set = try GenSet.init(allocator, bit_len),
                .handler_reach = try GenSet.init(allocator, bit_len),
                .normal_reach = try GenSet.init(allocator, bit_len),
                .queue = .{},
            };
        }

        fn ensureSize(self: *TryScratch, allocator: Allocator, bit_len: usize) !void {
            try self.handler_set.ensureSize(allocator, bit_len);
            try self.protected_set.ensureSize(allocator, bit_len);
            try self.handler_reach.ensureSize(allocator, bit_len);
            try self.normal_reach.ensureSize(allocator, bit_len);
            if (bit_len > self.queue.capacity) {
                try self.queue.ensureTotalCapacity(allocator, bit_len);
            }
            self.queue.clearRetainingCapacity();
        }

        fn deinit(self: *TryScratch, allocator: Allocator) void {
            self.handler_set.deinit(allocator);
            self.protected_set.deinit(allocator);
            self.handler_reach.deinit(allocator);
            self.normal_reach.deinit(allocator);
            self.queue.deinit(allocator);
        }
    };

    fn getTryScratch(self: *Decompiler, bit_len: usize) DecompileError!*TryScratch {
        if (self.try_scratch) |*scratch| {
            try scratch.ensureSize(self.allocator, bit_len);
            return scratch;
        }
        var scratch = try TryScratch.init(self.allocator, bit_len);
        try scratch.ensureSize(self.allocator, bit_len);
        self.try_scratch = scratch;
        return &self.try_scratch.?;
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

    fn isExprOnlyBlock(self: *Decompiler, block_id: u32) bool {
        if (block_id >= self.cfg.blocks.len) return false;
        const blk = &self.cfg.blocks[block_id];
        for (blk.instructions) |inst| {
            if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) return false;
            if (inst.isUnconditionalJump()) return false;
            if (isStatementOpcode(inst.opcode)) return false;
        }
        return true;
    }

    fn condBlockHasPrelude(block: *const BasicBlock) bool {
        for (block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) return false;
            if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
            if (isStatementOpcode(inst.opcode)) return true;
        }
        return false;
    }

    fn condChainAllTrueJumps(self: *Decompiler, start: u32, stop: u32) DecompileError!bool {
        if (start >= self.cfg.blocks.len) return false;
        if (stop >= self.cfg.blocks.len) return false;
        var seen = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer seen.deinit();
        var cur = start;
        while (true) {
            if (cur == stop) return true;
            if (cur >= self.cfg.blocks.len) return false;
            if (seen.isSet(cur)) return false;
            seen.set(cur);
            const blk = &self.cfg.blocks[cur];
            const term = blk.terminator() orelse return false;
            switch (term.opcode) {
                .POP_JUMP_IF_TRUE,
                .POP_JUMP_FORWARD_IF_TRUE,
                .POP_JUMP_BACKWARD_IF_TRUE,
                .JUMP_IF_TRUE,
                => {},
                else => return false,
            }
            var next_false: ?u32 = null;
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.edge_type == .conditional_false) {
                    next_false = edge.target;
                }
            }
            if (next_false == null) return false;
            cur = next_false.?;
        }
    }

    fn condChainFalseTarget(self: *Decompiler, start: u32, then_block: u32) DecompileError!?u32 {
        if (start >= self.cfg.blocks.len) return null;
        if (then_block >= self.cfg.blocks.len) return null;
        var seen = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer seen.deinit();
        var cur = start;
        while (true) {
            if (cur >= self.cfg.blocks.len) return null;
            if (seen.isSet(cur)) return null;
            seen.set(cur);
            const blk = &self.cfg.blocks[cur];
            const term = blk.terminator() orelse return null;
            if (!ctrl.Analyzer.isConditionalJump(undefined, term.opcode)) return null;
            if (condBlockHasPrelude(blk)) return null;
            var t_id: ?u32 = null;
            var f_id: ?u32 = null;
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.edge_type == .conditional_false) {
                    f_id = edge.target;
                } else if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                    t_id = edge.target;
                }
            }
            if (t_id == null or f_id == null) return null;
            var next: u32 = undefined;
            if (t_id.? == then_block and f_id.? != then_block) {
                next = f_id.?;
            } else if (f_id.? == then_block and t_id.? != then_block) {
                next = t_id.?;
            } else {
                return null;
            }
            if (next >= self.cfg.blocks.len) return null;
            const next_blk = &self.cfg.blocks[next];
            const next_term = next_blk.terminator() orelse return next;
            if (!ctrl.Analyzer.isConditionalJump(undefined, next_term.opcode)) return next;
            if (condBlockHasPrelude(next_blk)) return next;
            var next_has_then = false;
            for (next_blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target == then_block) {
                    next_has_then = true;
                    break;
                }
            }
            if (!next_has_then) return next;
            cur = next;
        }
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
                const value = sim.stack.pop() orelse {
                    if (sim.lenient) return null;
                    return error.StackUnderflow;
                };
                errdefer value.deinit(sim.allocator, sim.stack_alloc);
                return try self.handleStoreValue(name, value);
            },
            .POP_TOP => {
                const val = sim.stack.pop() orelse {
                    if (sim.lenient) return null;
                    return error.StackUnderflow;
                };
                switch (val) {
                    .expr => |e| {
                        return self.makeExprStmt(e) catch |err| {
                            if (err == error.SkipStatement) {
                                // Skipped expression - arena-allocated, don't free
                                return null;
                            }
                            return err;
                        };
                    },
                    else => {
                        val.deinit(sim.allocator, sim.stack_alloc);
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
                const target = try self.makeName(name, .del);
                const targets = try a.alloc(*Expr, 1);
                targets[0] = target;
                const stmt = try a.create(Stmt);
                stmt.* = .{ .delete = .{ .targets = targets } };
                return stmt;
            },
            .DELETE_ATTR => {
                const obj = try sim.stack.popExpr();
                const attr = sim.getName(inst.arg) orelse "<unknown>";
                const a = self.arena.allocator();
                const target = try self.makeAttribute(obj, attr, .del);
                const targets = try a.alloc(*Expr, 1);
                targets[0] = target;
                const stmt = try a.create(Stmt);
                stmt.* = .{ .delete = .{ .targets = targets } };
                return stmt;
            },
            .DELETE_SUBSCR => {
                const key = try sim.stack.popExpr();
                const container = try sim.stack.popExpr();
                const a = self.arena.allocator();
                const target = try ast.makeSubscript(a, container, key, .del);
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
                    val.deinit(sim.allocator, sim.stack_alloc);
                } else if (inst.arg == 2) {
                    const cause_val = sim.stack.pop() orelse return error.StackUnderflow;
                    errdefer cause_val.deinit(sim.allocator, sim.stack_alloc);
                    const exc_val = sim.stack.pop() orelse return error.StackUnderflow;
                    if (exc_val == .expr and cause_val == .expr) {
                        const a = self.arena.allocator();
                        const stmt = try a.create(Stmt);
                        stmt.* = .{ .raise_stmt = .{ .exc = exc_val.expr, .cause = cause_val.expr } };
                        return stmt;
                    }
                    exc_val.deinit(sim.allocator, sim.stack_alloc);
                    cause_val.deinit(sim.allocator, sim.stack_alloc);
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

    fn deinitStackValuesSlice(ast_alloc: Allocator, stack_alloc: Allocator, values: []const StackValue) void {
        for (values) |val| {
            val.deinit(ast_alloc, stack_alloc);
        }
        if (values.len > 0) stack_alloc.free(@constCast(values));
    }

    fn returnCleanupSkip(instructions: []const decoder.Instruction, idx: usize) ?usize {
        if (idx + 2 < instructions.len and
            instructions[idx].opcode == .ROT_TWO and
            instructions[idx + 1].opcode == .POP_TOP and
            instructions[idx + 2].opcode == .RETURN_VALUE)
        {
            return 2;
        }
        if (idx + 4 < instructions.len and
            instructions[idx].opcode == .ROT_TWO and
            instructions[idx + 1].opcode == .POP_TOP and
            instructions[idx + 2].opcode == .ROT_TWO and
            instructions[idx + 3].opcode == .POP_TOP and
            instructions[idx + 4].opcode == .RETURN_VALUE)
        {
            return 4;
        }
        return null;
    }

    fn isDocstringStmt(stmt: *const Stmt) bool {
        return switch (stmt.*) {
            .expr_stmt => |e| e.value.* == .constant and e.value.constant == .string,
            else => false,
        };
    }

    fn isAssignNameToName(stmt: *const Stmt, name: []const u8, value: []const u8) bool {
        if (stmt.* != .assign) return false;
        if (stmt.assign.targets.len != 1) return false;
        const target = stmt.assign.targets[0];
        if (target.* != .name) return false;
        if (!std.mem.eql(u8, target.name.id, name)) return false;
        const rhs = stmt.assign.value;
        if (rhs.* != .name) return false;
        return std.mem.eql(u8, rhs.name.id, value);
    }

    fn isAssignNameToQualname(stmt: *const Stmt, name: []const u8, class_name: []const u8) bool {
        if (stmt.* != .assign) return false;
        if (stmt.assign.targets.len != 1) return false;
        const target = stmt.assign.targets[0];
        if (target.* != .name) return false;
        if (!std.mem.eql(u8, target.name.id, name)) return false;
        const rhs = stmt.assign.value;
        if (rhs.* != .constant or rhs.constant != .string) return false;
        const qual = rhs.constant.string;
        if (std.mem.eql(u8, qual, class_name)) return true;
        return qual.len >= class_name.len and
            std.mem.eql(u8, qual[qual.len - class_name.len ..], class_name);
    }

    fn trimClassPrelude(self: *Decompiler, body: []const *Stmt, class_name: []const u8) []const *Stmt {
        _ = self;
        if (body.len == 0) return body;
        var idx: usize = 0;
        if (idx < body.len and isAssignNameToName(body[idx], "__module__", "__name__")) {
            idx += 1;
        }
        if (idx < body.len and isAssignNameToQualname(body[idx], "__qualname__", class_name)) {
            idx += 1;
        }
        return body[idx..];
    }

    fn isFutureImportStmt(stmt: *const Stmt) bool {
        return switch (stmt.*) {
            .import_from => |i| i.module != null and std.mem.eql(u8, i.module.?, "__future__"),
            else => false,
        };
    }

    fn isEmptyHandlerBody(body: []const *Stmt) bool {
        if (body.len == 0) return true;
        if (body.len == 1 and body[0].* == .pass) return true;
        return false;
    }

    fn reorderFutureImports(allocator: Allocator, stmts: []const *Stmt) Allocator.Error![]const *Stmt {
        if (stmts.len == 0) return stmts;

        var out = try allocator.alloc(*Stmt, stmts.len);
        var out_len: usize = 0;
        var start_idx: usize = 0;

        if (isDocstringStmt(stmts[0])) {
            out[out_len] = stmts[0];
            out_len += 1;
            start_idx = 1;
        }

        var has_future = false;
        for (stmts[start_idx..]) |stmt| {
            if (isFutureImportStmt(stmt)) {
                out[out_len] = stmt;
                out_len += 1;
                has_future = true;
            }
        }
        if (!has_future) {
            allocator.free(out);
            return stmts;
        }

        for (stmts[start_idx..]) |stmt| {
            if (isFutureImportStmt(stmt)) continue;
            out[out_len] = stmt;
            out_len += 1;
        }

        return out[0..out_len];
    }

    fn cloneStackValues(
        self: *Decompiler,
        values: []const StackValue,
    ) DecompileError![]StackValue {
        const out = try self.allocator.alloc(StackValue, values.len);
        var count: usize = 0;
        errdefer {
            for (out[0..count]) |val| {
                val.deinit(self.allocator, self.allocator);
            }
            self.allocator.free(out);
        }
        var clone_sim = &self.clone_sim;
        clone_sim.resetForClone();

        for (values, 0..) |val, idx| {
            out[idx] = try clone_sim.cloneStackValue(val);
            count += 1;
        }

        return out;
    }

    fn cloneStackValuesWithExpr(
        self: *Decompiler,
        values: []const StackValue,
        expr: *Expr,
    ) DecompileError![]StackValue {
        const out = try self.allocator.alloc(StackValue, values.len + 1);
        var count: usize = 0;
        errdefer {
            for (out[0..count]) |val| val.deinit(self.allocator, self.allocator);
            self.allocator.free(out);
        }

        var clone_sim = &self.clone_sim;
        clone_sim.resetForClone();

        for (values, 0..) |val, idx| {
            out[idx] = try clone_sim.cloneStackValue(val);
            count += 1;
        }
        out[values.len] = try clone_sim.cloneStackValue(.{ .expr = expr });
        count += 1;

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

    fn cloneStackValuesArena(
        self: *Decompiler,
        sim: *SimContext,
        values: []const StackValue,
    ) DecompileError![]StackValue {
        if (values.len == 0) return &.{};

        const out = try self.allocator.alloc(StackValue, values.len);
        errdefer self.allocator.free(out);

        for (values, 0..) |val, idx| {
            out[idx] = try sim.cloneStackValue(val);
        }

        return out;
    }

    fn cloneStackValuesArenaFlow(
        self: *Decompiler,
        sim: *SimContext,
        values: []const StackValue,
    ) DecompileError![]StackValue {
        if (values.len == 0) return &.{};

        const out = try self.allocator.alloc(StackValue, values.len);
        errdefer self.allocator.free(out);

        for (values, 0..) |val, idx| {
            out[idx] = try sim.cloneStackValueFlow(val);
        }

        return out;
    }

    fn mergeStackEntry(
        self: *Decompiler,
        existing_opt: ?[]StackValue,
        incoming: []const StackValue,
        clone_sim: *SimContext,
        flow_mode: bool,
    ) DecompileError!?[]StackValue {
        if (existing_opt == null) {
            if (flow_mode) {
                return try self.cloneStackValuesArenaFlow(clone_sim, incoming);
            }
            return try self.cloneStackValuesArena(clone_sim, incoming);
        }

        const existing = existing_opt.?;
        const existing_len = existing.len;
        const incoming_len = incoming.len;
        if (existing_len == 0 and incoming_len == 0) return null;

        const max_len = @max(existing_len, incoming_len);
        const existing_off = max_len - existing_len;
        const incoming_off = max_len - incoming_len;

        if (existing_len == max_len) {
            var unchanged = true;
            for (0..max_len) |idx| {
                const cur = existing[idx];
                const inc_opt: ?StackValue = if (idx >= incoming_off) incoming[idx - incoming_off] else null;
                const next: StackValue = if (inc_opt) |inc| blk: {
                    if (cur == .unknown) break :blk cur;
                    if (stack_mod.stackValueEqual(cur, inc)) break :blk cur;
                    break :blk .unknown;
                } else .unknown;
                if (!stack_mod.stackValueEqual(cur, next)) {
                    unchanged = false;
                    break;
                }
            }
            if (unchanged) return null;
        }

        var changed = false;
        const out = try self.allocator.alloc(StackValue, max_len);
        errdefer self.allocator.free(out);

        for (0..max_len) |idx| {
            const cur_opt: ?StackValue = if (idx >= existing_off) existing[idx - existing_off] else null;
            const inc_opt: ?StackValue = if (idx >= incoming_off) incoming[idx - incoming_off] else null;

            if (cur_opt == null or inc_opt == null) {
                out[idx] = .unknown;
                changed = true;
                continue;
            }

            const cur = cur_opt.?;
            const inc = inc_opt.?;
            if (cur == .unknown) {
                out[idx] = cur;
                continue;
            }
            if (stack_mod.stackValueEqual(cur, inc)) {
                out[idx] = cur;
                continue;
            }
            out[idx] = .unknown;
            changed = true;
        }

        if (!changed) {
            self.allocator.free(out);
            return null;
        }

        return out;
    }

    fn initStackFlow(self: *Decompiler) DecompileError!void {
        const block_count: u32 = @intCast(self.cfg.blocks.len);
        if (block_count == 0) {
            self.stack_in = &.{};
            return;
        }

        self.stack_in = try self.allocator.alloc(?[]StackValue, block_count);
        errdefer {
            for (self.stack_in) |entry_opt| {
                if (entry_opt) |entry| {
                    if (entry.len > 0) self.allocator.free(entry);
                }
            }
            self.allocator.free(self.stack_in);
            self.stack_in = &.{};
        }
        for (self.stack_in) |*slot| {
            slot.* = null;
        }

        var worklist: std.ArrayListUnmanaged(u32) = .{};
        defer worklist.deinit(self.allocator);

        self.stack_in[0] = &.{};
        try worklist.append(self.allocator, 0);

        var clone_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        clone_sim.flow_mode = true;
        clone_sim.stack.allow_underflow = true;
        defer clone_sim.deinit();

        while (worklist.items.len > 0) {
            const bid = worklist.items[worklist.items.len - 1];
            worklist.items.len -= 1;

            const entry = self.stack_in[bid] orelse continue;

            var sim_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer sim_arena.deinit();

            var sim = self.initSim(sim_arena.allocator(), sim_arena.allocator(), self.code, self.version);
            defer sim.deinit();
            sim.lenient = true;
            sim.flow_mode = true;
            sim.stack.allow_underflow = true;

            for (entry) |val| {
                const cloned = try clone_sim.cloneStackValueFlow(val);
                try sim.stack.push(cloned);
            }

            const block = &self.cfg.blocks[bid];
            var simulate_failed = false;
            for (block.instructions) |inst| {
                sim.simulate(inst) catch |err| {
                    if (sim.lenient and (err == error.NotAnExpression or err == error.StackUnderflow or err == error.InvalidStackDepth)) {
                        simulate_failed = true;
                        break;
                    }
                    return err;
                };
            }
            if (simulate_failed) continue;

            const exit = try self.cloneStackValuesArenaFlow(&clone_sim, sim.stack.items.items);
            defer if (exit.len > 0) self.allocator.free(exit);
            const term = block.terminator();
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const succ = edge.target;
                if (succ >= block_count) continue;
                if (self.cfg.blocks[succ].is_exception_handler) continue;

                var incoming = exit;
                if (term) |t| switch (t.opcode) {
                    .FOR_ITER => {
                        if (edge.edge_type == .conditional_false) {
                            const false_len = if (incoming.len >= 2) incoming.len - 2 else 0;
                            incoming = incoming[0..false_len];
                        }
                    },
                    .JUMP_IF_TRUE_OR_POP => {
                        if (edge.edge_type == .conditional_false) {
                            const false_len = if (incoming.len >= 1) incoming.len - 1 else 0;
                            incoming = incoming[0..false_len];
                        }
                    },
                    .JUMP_IF_FALSE_OR_POP => {
                        if (edge.edge_type == .conditional_true) {
                            const true_len = if (incoming.len >= 1) incoming.len - 1 else 0;
                            incoming = incoming[0..true_len];
                        }
                    },
                    else => {},
                };

                const merged = try self.mergeStackEntry(self.stack_in[succ], incoming, &clone_sim, true);
                if (merged) |new_entry| {
                    if (self.stack_in[succ]) |old| {
                        if (old.len > 0) self.allocator.free(old);
                    }
                    self.stack_in[succ] = new_entry;
                    try worklist.append(self.allocator, succ);
                }
            }
        }
    }

    fn processBlockWithSim(
        self: *Decompiler,
        block: *const BasicBlock,
        sim: *SimContext,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
    ) DecompileError!void {
        return self.processBlockWithSimAndSkip(block, sim, stmts, stmts_allocator, 0);
    }

    const UnpackTgts = struct {
        tgts: []*Expr,
        skip: usize,
        ok: bool,
    };

    fn starTgt(
        self: *Decompiler,
        arena: Allocator,
        tgt: *Expr,
        idx: usize,
        star_pos: ?u32,
    ) DecompileError!*Expr {
        _ = self;
        if (star_pos == null or idx != @as(usize, star_pos.?)) return tgt;
        const starred = try arena.create(Expr);
        starred.* = .{ .starred = .{ .value = tgt, .ctx = .store } };
        return starred;
    }

    fn collectUnpackTgts(
        self: *Decompiler,
        sim: *SimContext,
        instructions: []const decoder.Instruction,
        unpack_idx: usize,
        arena: Allocator,
    ) DecompileError!?UnpackTgts {
        if (unpack_idx >= instructions.len) return null;
        const inst = instructions[unpack_idx];
        if (inst.opcode != .UNPACK_SEQUENCE and inst.opcode != .UNPACK_EX) return null;

        const cnt = if (inst.opcode == .UNPACK_EX) blk: {
            const before = inst.arg & 0xFF;
            const after = (inst.arg >> 8) & 0xFF;
            break :blk before + 1 + after;
        } else inst.arg;
        const cnt_usize: usize = @intCast(cnt);

        const star_pos: ?u32 = if (inst.opcode == .UNPACK_EX) blk: {
            const before = inst.arg & 0xFF;
            break :blk before;
        } else null;

        var tgts = try std.ArrayList(*Expr).initCapacity(arena, cnt_usize);
        var skip: usize = 0;
        var inst_idx: usize = unpack_idx + 1;
        var found: usize = 0;

        while (found < cnt_usize and inst_idx < instructions.len) {
            const cur = instructions[inst_idx];
            if (cur.opcode == .STORE_FAST_STORE_FAST and found + 1 < cnt_usize) {
                const idx1 = (cur.arg >> 4) & 0xF;
                const idx2 = cur.arg & 0xF;
                if (sim.getLocal(idx1)) |n1| {
                    var t1 = try self.makeName(n1, .store);
                    t1 = try self.starTgt(arena, t1, found, star_pos);
                    try tgts.append(arena, t1);
                }
                if (sim.getLocal(idx2)) |n2| {
                    var t2 = try self.makeName(n2, .store);
                    t2 = try self.starTgt(arena, t2, found + 1, star_pos);
                    try tgts.append(arena, t2);
                }
                found += 2;
                skip += 1;
                inst_idx += 1;
                continue;
            }

            const name: ?[]const u8 = switch (cur.opcode) {
                .STORE_NAME, .STORE_GLOBAL => sim.getName(cur.arg),
                .STORE_FAST => sim.getLocal(cur.arg),
                .STORE_DEREF => sim.getDeref(cur.arg),
                else => null,
            };
            if (name) |n| {
                var t = try self.makeName(n, .store);
                t = try self.starTgt(arena, t, found, star_pos);
                try tgts.append(arena, t);
                found += 1;
                skip += 1;
                inst_idx += 1;
                continue;
            }

            if (isLoadInstr(cur.opcode)) {
                if (try self.tryParseSubscriptTarget(sim, instructions, inst_idx, arena)) |result| {
                    var t = result.target;
                    t = try self.starTgt(arena, t, found, star_pos);
                    try tgts.append(arena, t);
                    found += 1;
                    skip += result.next_idx - inst_idx;
                    inst_idx = result.next_idx;
                    continue;
                }
            }
            break;
        }

        return .{ .tgts = tgts.items, .skip = skip, .ok = tgts.items.len == cnt_usize };
    }

    fn handleUnpack(
        self: *Decompiler,
        sim: *SimContext,
        instructions: []const decoder.Instruction,
        idx: usize,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
    ) DecompileError!usize {
        const inst = instructions[idx];
        const count = if (inst.opcode == .UNPACK_EX) blk: {
            const before = inst.arg & 0xFF;
            const after = (inst.arg >> 8) & 0xFF;
            break :blk before + 1 + after;
        } else inst.arg;
        const seq_expr = try sim.stack.popExpr();
        const arena = self.arena.allocator();

        const unpack = try self.collectUnpackTgts(sim, instructions, idx, arena);
        if (unpack != null and unpack.?.ok) {
            const targets = unpack.?.tgts;
            // Check for pending chain targets from preceding STORE_ATTR
            const has_pending = self.pending_chain_targets.items.len > 0;
            if (has_pending) {
                // Combine pending targets with unpack targets
                // Create: self.a = (self.b, self.c) = expr
                const all_targets = try arena.alloc(*Expr, 1 + self.pending_chain_targets.items.len);

                // First, create tuple from unpack targets
                const tuple_expr = try arena.create(Expr);
                tuple_expr.* = .{ .tuple = .{
                    .elts = try arena.dupe(*Expr, targets),
                    .ctx = .store,
                } };

                // Put pending targets first (leftmost in chain), then tuple
                for (self.pending_chain_targets.items, 0..) |t, t_idx| {
                    all_targets[t_idx] = t;
                }
                all_targets[self.pending_chain_targets.items.len] = tuple_expr;
                self.pending_chain_targets.clearRetainingCapacity();

                const stmt = try arena.create(Stmt);
                stmt.* = .{ .assign = .{
                    .targets = all_targets,
                    .value = seq_expr,
                    .type_comment = null,
                } };
                try stmts.append(stmts_allocator, stmt);
                return unpack.?.skip;
            }
            // Generate unpacking assignment: a, b, c = expr
            const stmt = try self.makeUnpackAssignExprs(targets, seq_expr);
            try stmts.append(stmts_allocator, stmt);
            return unpack.?.skip;
        }

        // Fallback: push unknown for each element
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            try sim.stack.push(.unknown);
        }
        return 0;
    }

    fn processBlockWithSimAndSkip(
        self: *Decompiler,
        block: *const BasicBlock,
        sim: *SimContext,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
        skip_first: usize,
    ) DecompileError!void {
        // Check for pending ternary expression from tryDecompileTernaryInto
        // For inline comprehensions (Python 3.12+), we need to skip cleanup ops
        // before pushing the expression: END_FOR, POP_TOP, SWAP, STORE_FAST (loop var restore)
        var extra_skip: usize = 0;
        if (self.pending_vals) |vals| {
            for (vals) |val| {
                const cloned = try sim.cloneStackValue(val);
                try sim.stack.push(cloned);
            }
            deinitStackValuesSlice(self.allocator, self.allocator, vals);
            self.pending_vals = null;
        }
        if (self.pending_store_expr) |expr| {
            try sim.stack.push(.{ .expr = expr });
            self.pending_store_expr = null;
        }
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
        if (sim.stack.len() == 0) {
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }

        const instructions = block.instructions[skip_first + extra_skip ..];
        var i: usize = 0;
        while (i < instructions.len) : (i += 1) {
            const inst = instructions[i];

            // Stop at POP_EXCEPT - marks end of except handler body, cleanup follows
            if (inst.opcode == .POP_EXCEPT) break;
            if (returnCleanupSkip(instructions, i)) |skip| {
                i += skip - 1;
                continue;
            }

            errdefer if (self.last_error_ctx == null) {
                self.last_error_ctx = .{
                    .code_name = self.code.name,
                    .block_id = block.id,
                    .offset = inst.offset,
                    .opcode = inst.opcode.name(),
                };
            };
            if (inst.opcode == .IMPORT_NAME) {
                if (try self.tryDecompileImportFromGroup(sim, instructions, i, stmts, stmts_allocator)) |end_idx| {
                    i = end_idx;
                    continue;
                }
            }
            switch (inst.opcode) {
                .UNPACK_SEQUENCE, .UNPACK_EX => {
                    const skip_count = try self.handleUnpack(sim, instructions, i, stmts, stmts_allocator);
                    i += skip_count;
                    continue;
                },
                .STORE_NAME, .STORE_FAST, .STORE_GLOBAL, .STORE_DEREF => {
                    // Check for chain assignment pattern: DUP_TOP before STORE indicates chained assignment
                    const real_idx = skip_first + i;
                    const prev_was_dup = if (real_idx > 0) blk: {
                        const prev = block.instructions[real_idx - 1];
                        break :blk prev.opcode == .DUP_TOP or prev.opcode == .COPY;
                    } else false;

                    const name = switch (inst.opcode) {
                        .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                        .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                        .STORE_DEREF => sim.getDeref(inst.arg) orelse "<unknown>",
                        else => "<unknown>",
                    };

                    const is_classcell = inst.opcode == .STORE_NAME and std.mem.eql(u8, name, "__classcell__");

                    if (is_classcell) {
                        _ = sim.stack.pop() orelse return error.StackUnderflow;
                        self.saw_classcell = true;
                        continue;
                    }

                    if (prev_was_dup and !is_classcell) {
                        // This is a chain assignment. Collect all targets.
                        const arena = self.arena.allocator();
                        var targets: std.ArrayList(*Expr) = .{};

                        // Add current target
                        const first_target = try self.makeName(name, .store);
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
                                            const target = try self.makeName(sn, .store);
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
                                            const t1 = try self.makeName(n1, .store);
                                            try targets.append(arena, t1);
                                        }
                                        if (sim.getLocal(idx2)) |n2| {
                                            const t2 = try self.makeName(n2, .store);
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
                                                    const t1 = try self.makeName(n1, .store);
                                                    try tup_targets.append(arena, t1);
                                                    found += 1;
                                                }
                                                if (sim.getLocal(idx2)) |n2| {
                                                    const t2 = try self.makeName(n2, .store);
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
                                                const tgt = try self.makeName(nm, .store);
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
                                    const target = try self.makeName(sn, .store);
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
                                            const t1 = try self.makeName(n1, .store);
                                            try tuple_targets.append(arena, t1);
                                            targets_found += 1;
                                        }
                                        if (sim.getLocal(idx2)) |n2| {
                                            const t2 = try self.makeName(n2, .store);
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
                                    if (un) |tgt_name| {
                                        const t = try self.makeName(tgt_name, .store);
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
                                    // Consume unpack placeholders to keep stack aligned.
                                    var u: usize = 0;
                                    while (u < unpack_count) : (u += 1) {
                                        _ = sim.stack.pop() orelse break;
                                    }
                                }
                                break;
                            } else {
                                break;
                            }
                        }

                        // Get the actual value (last one on stack)
                        const value_opt = sim.stack.pop();
                        if (value_opt) |value| {
                            if (value == .expr) {
                                // Create chain assignment: target1 = target2 = ... = value
                                const stmt = try arena.create(Stmt);
                                stmt.* = .{ .assign = .{
                                    .targets = targets.items,
                                    .value = value.expr,
                                    .type_comment = null,
                                } };
                                try stmts.append(stmts_allocator, stmt);
                            }
                        } else {
                            const placeholder = try ast.makeConstant(arena, .ellipsis);
                            const stmt = try arena.create(Stmt);
                            stmt.* = .{ .assign = .{
                                .targets = targets.items,
                                .value = placeholder,
                                .type_comment = null,
                            } };
                            try stmts.append(stmts_allocator, stmt);
                        }

                        // Skip processed instructions
                        i = j - 1; // -1 because loop will increment
                        continue;
                    }

                    // Regular single assignment
                    const value_opt = sim.stack.pop();
                    if (value_opt == null) {
                        if (try self.tryRecoverFunctionDefFromMakeFunction(sim, instructions, i, name)) |stmt| {
                            try stmts.append(stmts_allocator, stmt);
                            continue;
                        }
                    }
                    const value = value_opt orelse StackValue.unknown;
                    errdefer value.deinit(sim.allocator, sim.stack_alloc);

                    // Check for augmented assignment: x = x + 5 -> x += 5
                    if (value == .expr and value.expr.* == .bin_op and sim.isInplaceExpr(value.expr)) {
                        const binop = &value.expr.bin_op;
                        if (binop.left.* == .name and std.mem.eql(u8, binop.left.name.id, name)) {
                            const arena = self.arena.allocator();
                            binop.left.deinit(arena);
                            arena.destroy(binop.left);
                            const stmt = try arena.create(Stmt);
                            const target = try self.makeName(name, .store);
                            stmt.* = .{ .aug_assign = .{
                                .target = target,
                                .op = binop.op,
                                .value = binop.right,
                            } };
                            arena.destroy(value.expr);
                            try stmts.append(stmts_allocator, stmt);
                            continue;
                        }
                    }

                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(stmts_allocator, stmt);
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
                        const key_val = sim.stack.pop() orelse {
                            try sim.simulate(inst);
                            continue;
                        };
                        const container_val = sim.stack.pop() orelse {
                            try sim.simulate(inst);
                            continue;
                        };
                        _ = sim.stack.pop() orelse {
                            try sim.simulate(inst);
                            continue;
                        }; // pop dup'd value

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
                                            const target = try self.makeName(sn, .store);
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
                                                const t = try self.makeName(name, .store);
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
                                        const t = try self.makeName(name, .store);
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
                                    const target = try self.makeName(sn, .store);
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
                            if (targets.items.len == 1) {
                                if (try self.tryMakeAugAssign(sim, targets.items[0], value.expr)) |stmt| {
                                    try stmts.append(stmts_allocator, stmt);
                                    i = j - 1;
                                    continue;
                                }
                            }
                            const stmt = try arena.create(Stmt);
                            stmt.* = .{ .assign = .{
                                .targets = targets.items,
                                .value = value.expr,
                                .type_comment = null,
                            } };
                            try stmts.append(stmts_allocator, stmt);
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
                        const target = try self.makeName(var_name, .store);

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
                        try stmts.append(stmts_allocator, stmt);
                    } else {
                        const subscript = try a.create(Expr);
                        subscript.* = .{ .subscript = .{
                            .value = container,
                            .slice = key,
                            .ctx = .store,
                        } };
                        if (try self.tryMakeAugAssign(sim, subscript, value)) |stmt| {
                            try stmts.append(stmts_allocator, stmt);
                        } else {
                            const stmt = try self.makeAssign(subscript, value);
                            try stmts.append(stmts_allocator, stmt);
                        }
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
                    if (try self.tryMakeAugAssign(sim, subscript, value)) |stmt| {
                        try stmts.append(stmts_allocator, stmt);
                    } else {
                        const stmt = try self.makeAssign(subscript, value);
                        try stmts.append(stmts_allocator, stmt);
                    }
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
                        const container_val = sim.stack.pop() orelse return error.StackUnderflow;
                        _ = sim.stack.pop() orelse return error.StackUnderflow; // pop dup'd value
                        if (container_val == .expr) {
                            const attr_name = sim.getName(inst.arg) orelse "<unknown>";
                            const target = try self.makeAttribute(container_val.expr, attr_name, .store);
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
                            const first_target = try self.makeAttribute(container_val.expr, attr_name, .store);
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
                                            const target = try self.makeAttribute(cont_val.expr, attr, .store);
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
                                // Final attr target (no DUP), possibly through LOAD_ATTR chain.
                                var k: usize = j;
                                try sim.simulate(instructions[k]);
                                k += 1;
                                while (k < instructions.len and instructions[k].opcode == .LOAD_ATTR) {
                                    try sim.simulate(instructions[k]);
                                    k += 1;
                                }
                                if (k < instructions.len and instructions[k].opcode == .STORE_ATTR) {
                                    const cont_val = sim.stack.pop() orelse return error.StackUnderflow;
                                    if (cont_val == .expr) {
                                        const attr = sim.getName(instructions[k].arg) orelse "<unknown>";
                                        const target = try self.makeAttribute(cont_val.expr, attr, .store);
                                        try targets.append(arena, target);
                                    }
                                    j = k + 1;
                                }
                                break;
                            } else {
                                break;
                            }
                        }

                        // Get the value
                        const value = sim.stack.pop() orelse return error.StackUnderflow;
                        if (value == .expr and targets.items.len > 0) {
                            if (targets.items.len == 1) {
                                if (try self.tryMakeAugAssign(sim, targets.items[0], value.expr)) |stmt| {
                                    try stmts.append(stmts_allocator, stmt);
                                    i = j - 1;
                                    continue;
                                }
                            }
                            const stmt = try arena.create(Stmt);
                            stmt.* = .{ .assign = .{
                                .targets = targets.items,
                                .value = value.expr,
                                .type_comment = null,
                            } };
                            try stmts.append(stmts_allocator, stmt);
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

                    const attr_name = sim.getName(inst.arg) orelse "<unknown>";
                    const attr_expr = try self.makeAttribute(container, attr_name, .store);
                    if (try self.tryMakeAugAssign(sim, attr_expr, value)) |stmt| {
                        try stmts.append(stmts_allocator, stmt);
                    } else {
                        const stmt = try self.makeAssign(attr_expr, value);
                        try stmts.append(stmts_allocator, stmt);
                    }
                },
                .RETURN_VALUE => {
                    if (self.saw_classcell) {
                        _ = sim.stack.pop() orelse return error.StackUnderflow;
                        self.saw_classcell = false;
                        continue;
                    }
                    const value = try sim.stack.popExpr();
                    // Skip 'return None' at module level (implicit return)
                    if (self.isModuleLevel() and value.* == .constant and value.constant == .none) {
                        continue;
                    }
                    const stmt = try self.makeReturn(value);
                    try stmts.append(stmts_allocator, stmt);
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const value = try sim.objToExpr(obj);
                        // Skip 'return None' at module level (implicit return)
                        if (self.isModuleLevel() and value.* == .constant and value.constant == .none) {
                            continue;
                        }
                        const stmt = try self.makeReturn(value);
                        try stmts.append(stmts_allocator, stmt);
                    }
                },
                .POP_TOP => {
                    try self.handlePopTopStmt(sim, block, stmts, stmts_allocator);
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
                    try stmts.append(stmts_allocator, stmt);
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
                    try stmts.append(stmts_allocator, stmt);
                },
                .RAISE_VARARGS, .DELETE_NAME, .DELETE_FAST, .DELETE_GLOBAL, .DELETE_DEREF, .DELETE_ATTR, .DELETE_SUBSCR => {
                    if (try self.tryEmitStatement(inst, sim)) |stmt| {
                        try stmts.append(stmts_allocator, stmt);
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

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (base_vals) |val| {
            try sim.stack.push(try sim.cloneStackValue(val));
        }

        for (block.instructions) |inst| {
            if (inst.isConditionalJump()) return null;
            if (inst.isUnconditionalJump()) break;
            if (isStatementOpcode(inst.opcode)) return null;
            if (!try simOpt(&sim, inst)) return null;
        }

        if (sim.stack.len() != base_vals.len + 1) return null;
        return (try popExprOpt(&sim)) orelse null;
    }

    fn simulateConditionExpr(
        self: *Decompiler,
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
            if (isStatementOpcode(inst.opcode)) return null;
            if (!try simOpt(&sim, inst)) return null;
        }

        const expr = (try popExprOpt(&sim)) orelse return null;
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

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (base_vals) |val| {
            try sim.stack.push(try sim.cloneStackValue(val));
        }

        for (block.instructions[skip..]) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (inst.isUnconditionalJump()) break;
            if (isStatementOpcode(inst.opcode)) break;
            if (!try simOpt(&sim, inst)) return null;
        }

        if (sim.stack.len() != base_vals.len + 1) return null;
        return (try popExprOpt(&sim)) orelse null;
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
            if (isStatementOpcode(inst.opcode)) return null;
            if (!try simOpt(&sim, inst)) return null;
        }

        const expr = (try popExprOpt(&sim)) orelse return null;
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
        stmts_allocator: Allocator,
    ) DecompileError!?CondSim {
        if (block_id >= self.cfg.blocks.len) return null;
        const cond_block = &self.cfg.blocks[block_id];

        var cond_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer cond_sim.deinit();
        cond_sim.lenient = true;

        if (self.pending_vals) |vals| {
            for (vals) |val| {
                const cloned = try cond_sim.cloneStackValue(val);
                try cond_sim.stack.push(cloned);
            }
        }
        if (self.pending_ternary_expr) |expr| {
            try cond_sim.stack.push(.{ .expr = expr });
            self.pending_ternary_expr = null;
        }

        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (isStatementOpcode(inst.opcode)) {
                const stmt_opt = try self.tryEmitStatement(inst, &cond_sim);
                if (stmt_opt) |stmt| {
                    try stmts.append(stmts_allocator, stmt);
                }
            } else {
                if (!try simOpt(&cond_sim, inst)) return null;
            }
        }

        const expr = (try popExprOpt(&cond_sim)) orelse return null;
        const base_vals = try self.cloneStackValues(cond_sim.stack.items.items);
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
        try self.cond_seen.ensureSize(self.allocator, self.cfg.blocks.len);
        self.cond_seen.reset();
        self.cond_stack.clearRetainingCapacity();

        try self.cond_stack.append(self.allocator, start);
        while (self.cond_stack.items.len > 0) {
            const cur = self.cond_stack.items[self.cond_stack.items.len - 1];
            self.cond_stack.items.len -= 1;
            if (cur >= self.cfg.blocks.len) continue;
            if (self.cond_seen.isSet(cur)) continue;
            try self.cond_seen.set(self.allocator, cur);

            const blk = &self.cfg.blocks[cur];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const next = edge.target;
                if (next == target) return true;
                if (next == true_block or next == false_block) continue;
                try self.cond_stack.append(self.allocator, next);
            }
        }
        return false;
    }

    fn branchEnd(self: *Decompiler, start: u32, stop: ?u32) DecompileError!u32 {
        var limit: u32 = stop orelse @intCast(self.cfg.blocks.len);
        if (self.br_limit) |lim| {
            if (lim < limit) limit = lim;
        }
        if (start >= limit) return start;

        try self.cond_seen.ensureSize(self.allocator, self.cfg.blocks.len);
        self.cond_seen.reset();
        self.cond_stack.clearRetainingCapacity();
        try self.cond_stack.append(self.allocator, start);

        var max_block = start;
        while (self.cond_stack.items.len > 0) {
            const cur = self.cond_stack.items[self.cond_stack.items.len - 1];
            self.cond_stack.items.len -= 1;
            if (cur >= self.cfg.blocks.len) continue;
            if (cur >= limit) continue;
            if (cur < start) continue;
            if (self.cond_seen.isSet(cur)) continue;
            try self.cond_seen.set(self.allocator, cur);
            if (cur > max_block) max_block = cur;

            const blk = &self.cfg.blocks[cur];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const next = edge.target;
                if (next < start) continue;
                if (next >= limit) continue;
                if (stop) |stop_id| {
                    if (next == stop_id) continue;
                }
                if (!self.cond_seen.isSet(next)) {
                    try self.cond_stack.append(self.allocator, next);
                }
            }
        }

        const end = max_block + 1;
        return if (end > limit) limit else end;
    }

    fn reachableInRange(
        self: *Decompiler,
        start: u32,
        limit: u32,
        stop: ?u32,
    ) DecompileError!std.DynamicBitSet {
        var seen = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        if (start >= limit or start >= self.cfg.blocks.len) return seen;

        var stack: std.ArrayList(u32) = .{};
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, start);

        while (stack.items.len > 0) {
            const cur = stack.items[stack.items.len - 1];
            stack.items.len -= 1;
            if (cur >= self.cfg.blocks.len) continue;
            if (cur >= limit) continue;
            if (cur < start) continue;
            if (seen.isSet(cur)) continue;
            seen.set(cur);

            const blk = &self.cfg.blocks[cur];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const next = edge.target;
                if (stop) |stop_id| {
                    if (next == stop_id) continue;
                }
                if (next < start) continue;
                if (next >= limit) continue;
                if (!seen.isSet(next)) {
                    try stack.append(self.allocator, next);
                }
            }
        }

        return seen;
    }

    fn isTerminalBlock(self: *Decompiler, block_id: u32) bool {
        if (block_id >= self.cfg.blocks.len) return true;
        const block = &self.cfg.blocks[block_id];
        for (block.successors) |edge| {
            if (edge.edge_type != .exception) return false;
        }
        return true;
    }

    fn postDominates(self: *Decompiler, post: u32, node: u32) DecompileError!bool {
        const n = self.cfg.blocks.len;
        if (post >= n or node >= n) return false;
        try self.ensurePostDom();
        const idom = self.postdom_idom orelse return false;
        const total: u32 = @intCast(n + 1);
        return postdomDominatesIdom(idom, total, @intCast(n), post, node);
    }

    fn ensurePostDom(self: *Decompiler) DecompileError!void {
        if (self.postdom_idom != null) return;
        self.postdom_idom = try self.computePostDomIdom();
    }

    fn computePostDomIdom(self: *Decompiler) DecompileError![]u32 {
        const n = self.cfg.blocks.len;
        const total: usize = n + 1;
        const exit_id: u32 = @intCast(n);

        var succ_lists = try self.allocator.alloc(std.ArrayListUnmanaged(u32), total);
        errdefer self.allocator.free(succ_lists);
        var pred_lists = try self.allocator.alloc(std.ArrayListUnmanaged(u32), total);
        errdefer self.allocator.free(pred_lists);
        for (0..total) |i| {
            succ_lists[i] = .{};
            pred_lists[i] = .{};
        }
        errdefer {
            for (0..total) |i| {
                succ_lists[i].deinit(self.allocator);
                pred_lists[i].deinit(self.allocator);
            }
        }

        for (self.cfg.blocks, 0..) |blk, idx| {
            const u: u32 = @intCast(idx);
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const v = edge.target;
                if (v >= n) continue;
                try succ_lists[@intCast(v)].append(self.allocator, u);
                try pred_lists[@intCast(u)].append(self.allocator, v);
            }
        }

        for (0..n) |i| {
            const id: u32 = @intCast(i);
            if (self.isTerminalBlock(id)) {
                try succ_lists[@intCast(exit_id)].append(self.allocator, id);
                try pred_lists[@intCast(id)].append(self.allocator, exit_id);
            }
        }

        var succs = try self.allocator.alloc([]const u32, total);
        errdefer self.allocator.free(succs);
        var preds = try self.allocator.alloc([]const u32, total);
        errdefer self.allocator.free(preds);
        for (0..total) |i| {
            succs[i] = try succ_lists[i].toOwnedSlice(self.allocator);
            preds[i] = try pred_lists[i].toOwnedSlice(self.allocator);
        }
        for (0..total) |i| {
            succ_lists[i].deinit(self.allocator);
            pred_lists[i].deinit(self.allocator);
        }
        self.allocator.free(succ_lists);
        self.allocator.free(pred_lists);
        defer {
            for (0..total) |i| {
                if (succs[i].len > 0) self.allocator.free(succs[i]);
                if (preds[i].len > 0) self.allocator.free(preds[i]);
            }
            self.allocator.free(succs);
            self.allocator.free(preds);
        }

        return try computePostDomIdomFrom(self.allocator, succs, preds, exit_id);
    }

    fn computePostDomIdomFrom(
        allocator: Allocator,
        succs: []const []const u32,
        preds: []const []const u32,
        entry: u32,
    ) DecompileError![]u32 {
        const total: u32 = @intCast(succs.len);
        const count: usize = @intCast(total);
        const undef = std.math.maxInt(u32);

        var idom = try allocator.alloc(u32, count);
        @memset(idom, undef);

        const rpo = try computePostDomRpo(allocator, succs, entry);
        defer allocator.free(rpo);

        if (rpo.len == 0) {
            for (0..count) |i| {
                idom[i] = @intCast(i);
            }
            return idom;
        }

        var rpo_index = try allocator.alloc(u32, count);
        defer allocator.free(rpo_index);
        @memset(rpo_index, undef);
        for (rpo, 0..) |node, idx| {
            rpo_index[@intCast(node)] = @intCast(idx);
        }

        idom[@intCast(rpo[0])] = rpo[0];

        var changed = true;
        while (changed) {
            changed = false;
            for (rpo[1..]) |node| {
                const node_idx: usize = @intCast(node);
                var new_idom: ?u32 = null;

                for (preds[node_idx]) |pred| {
                    if (idom[@intCast(pred)] == undef) continue;
                    if (new_idom == null) {
                        new_idom = pred;
                    } else {
                        new_idom = postdomIntersectIdom(idom, rpo_index, pred, new_idom.?);
                    }
                }

                if (new_idom == null) continue;
                if (idom[node_idx] != new_idom.?) {
                    idom[node_idx] = new_idom.?;
                    changed = true;
                }
            }
        }

        for (idom, 0..) |*dom, i| {
            if (dom.* == undef) {
                dom.* = @intCast(i);
            }
        }

        return idom;
    }

    fn computePostDomRpo(
        allocator: Allocator,
        succs: []const []const u32,
        entry: u32,
    ) DecompileError![]u32 {
        if (entry >= succs.len) return &.{};
        var visited = try std.DynamicBitSet.initEmpty(allocator, succs.len);
        defer visited.deinit();

        var postorder: std.ArrayList(u32) = .{};
        errdefer postorder.deinit(allocator);

        var stack: std.ArrayList(struct { node: u32, next_idx: usize }) = .{};
        defer stack.deinit(allocator);

        visited.set(@intCast(entry));
        try stack.append(allocator, .{ .node = entry, .next_idx = 0 });

        while (stack.items.len > 0) {
            var frame = &stack.items[stack.items.len - 1];
            const node = frame.node;
            if (frame.next_idx < succs[@intCast(node)].len) {
                const next = succs[@intCast(node)][frame.next_idx];
                frame.next_idx += 1;
                if (next >= succs.len) continue;
                if (!visited.isSet(@intCast(next))) {
                    visited.set(@intCast(next));
                    try stack.append(allocator, .{ .node = next, .next_idx = 0 });
                }
            } else {
                try postorder.append(allocator, node);
                _ = stack.pop();
            }
        }

        const rpo = try postorder.toOwnedSlice(allocator);
        std.mem.reverse(u32, rpo);
        return rpo;
    }

    fn postdomIntersectIdom(idom: []const u32, rpo_index: []const u32, a: u32, b: u32) u32 {
        var finger1 = a;
        var finger2 = b;
        while (finger1 != finger2) {
            while (rpo_index[@intCast(finger1)] > rpo_index[@intCast(finger2)]) {
                finger1 = idom[@intCast(finger1)];
            }
            while (rpo_index[@intCast(finger2)] > rpo_index[@intCast(finger1)]) {
                finger2 = idom[@intCast(finger2)];
            }
        }
        return finger1;
    }

    fn postdomDominatesIdom(idom: []const u32, num_blocks: u32, entry: u32, a: u32, b: u32) bool {
        if (a >= num_blocks or b >= num_blocks) return false;
        if (a == b) return true;
        const b_idx: usize = @intCast(b);
        if (b != entry and idom[b_idx] == b) return false;

        var current = b;
        while (current != entry) {
            const parent = idom[@intCast(current)];
            if (parent == a) return true;
            if (parent == current) break;
            current = parent;
        }
        return a == entry;
    }

    const TerminalResult = struct {
        block_id: u32,
        stmt: *Stmt,
    };

    fn optExprEqual(a: ?*Expr, b: ?*Expr) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return ast.exprEqual(a.?, b.?);
    }

    fn stmtIsTerminal(_: *Decompiler, stmt: *const Stmt) bool {
        return switch (stmt.*) {
            .return_stmt, .raise_stmt => true,
            else => false,
        };
    }

    fn stmtAlwaysTerminal(self: *Decompiler, stmt: *const Stmt) bool {
        return switch (stmt.*) {
            .return_stmt, .raise_stmt => true,
            .if_stmt => |ifs| blk: {
                if (ifs.body.len == 0 or ifs.else_body.len == 0) break :blk false;
                break :blk self.bodyEndsTerminal(ifs.body) and self.bodyEndsTerminal(ifs.else_body);
            },
            else => false,
        };
    }

    fn terminalStmtEqual(_: *Decompiler, left: *const Stmt, right: *const Stmt) bool {
        return switch (left.*) {
            .return_stmt => |l| switch (right.*) {
                .return_stmt => |r| optExprEqual(l.value, r.value),
                else => false,
            },
            .raise_stmt => |l| switch (right.*) {
                .raise_stmt => |r| optExprEqual(l.exc, r.exc) and optExprEqual(l.cause, r.cause),
                else => false,
            },
            else => false,
        };
    }

    fn pruneTrailingTerminalInStmt(self: *Decompiler, stmt: *Stmt, term: *const Stmt) void {
        switch (stmt.*) {
            .if_stmt => |*if_stmt| {
                if (if_stmt.body.len > 0) {
                    const last = if_stmt.body[if_stmt.body.len - 1];
                    if (self.stmtIsTerminal(last) and self.terminalStmtEqual(last, term)) {
                        if_stmt.body = if_stmt.body[0 .. if_stmt.body.len - 1];
                    } else if (last.* == .if_stmt) {
                        self.pruneTrailingTerminalInStmt(@constCast(last), term);
                    }
                }
                if (if_stmt.else_body.len > 0) {
                    const last = if_stmt.else_body[if_stmt.else_body.len - 1];
                    if (self.stmtIsTerminal(last) and self.terminalStmtEqual(last, term)) {
                        if_stmt.else_body = if_stmt.else_body[0 .. if_stmt.else_body.len - 1];
                    } else if (last.* == .if_stmt) {
                        self.pruneTrailingTerminalInStmt(@constCast(last), term);
                    }
                }
            },
            else => {},
        }
    }

    fn bodyEndsTerminal(self: *Decompiler, body: []const *Stmt) bool {
        if (body.len == 0) return false;
        return self.stmtAlwaysTerminal(body[body.len - 1]);
    }

    fn appendStmt(
        _: *Decompiler,
        allocator: Allocator,
        body: []const *Stmt,
        stmt: *Stmt,
    ) DecompileError![]const *Stmt {
        const out = try allocator.alloc(*Stmt, body.len + 1);
        if (body.len > 0) {
            std.mem.copyForwards(*Stmt, out[0..body.len], body);
        }
        out[body.len] = stmt;
        return out;
    }

    const ImportGroup = struct {
        module: ?[]const u8,
        level: u32,
        names: []const []const u8,
    };

    fn constInt(self: *Decompiler, idx: u32) ?i64 {
        if (idx >= self.code.consts.len) return null;
        const obj = self.code.consts[idx];
        return switch (obj) {
            .int => |v| switch (v) {
                .small => |n| n,
                .big => |b| b.toI64(),
            },
            else => null,
        };
    }

    fn collectImportFromGroups(self: *Decompiler, allocator: Allocator) DecompileError![]const ImportGroup {
        var groups: std.ArrayList(ImportGroup) = .{};
        errdefer groups.deinit(allocator);

        const insts = self.cfg.instructions;
        var i: usize = 0;
        while (i < insts.len) : (i += 1) {
            const inst = insts[i];
            if (inst.opcode != .IMPORT_NAME) continue;
            const module_name = if (inst.arg < self.code.names.len) self.code.names[inst.arg] else continue;
            var level: u32 = 0;
            if (self.version.gte(2, 5) and i >= 2) {
                const lvl_inst = insts[i - 2];
                if (lvl_inst.opcode == .LOAD_CONST) {
                    if (self.constInt(lvl_inst.arg)) |v| {
                        if (v >= 0) level = @intCast(v);
                    }
                }
            }

            var names: std.ArrayList([]const u8) = .{};
            defer names.deinit(allocator);
            var j = i + 1;
            while (j + 1 < insts.len and insts[j].opcode == .IMPORT_FROM) {
                const attr = if (insts[j].arg < self.code.names.len) self.code.names[insts[j].arg] else break;
                const store_inst = insts[j + 1];
                switch (store_inst.opcode) {
                    .STORE_NAME, .STORE_GLOBAL, .STORE_FAST, .STORE_DEREF => {},
                    else => break,
                }
                try names.append(allocator, attr);
                j += 2;
            }
            if (names.items.len > 1 and j < insts.len and insts[j].opcode == .POP_TOP) {
                const names_copy = try allocator.alloc([]const u8, names.items.len);
                std.mem.copyForwards([]const u8, names_copy, names.items);
                try groups.append(allocator, .{
                    .module = if (module_name.len == 0) null else module_name,
                    .level = level,
                    .names = names_copy,
                });
            }
            if (j > i) i = j;
        }

        return groups.toOwnedSlice(allocator);
    }

    fn namesMatchGroup(aliases: []const ast.Alias, group_names: []const []const u8) bool {
        if (aliases.len != group_names.len) return false;
        for (aliases, 0..) |alias, idx| {
            if (!std.mem.eql(u8, alias.name, group_names[idx])) return false;
        }
        return true;
    }

    fn mergeImportFromGroups(
        self: *Decompiler,
        allocator: Allocator,
        stmts: []const *Stmt,
    ) DecompileError![]const *Stmt {
        const groups = try self.collectImportFromGroups(allocator);
        if (groups.len == 0) return stmts;

        var out: std.ArrayList(*Stmt) = .{};
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < stmts.len) {
            const stmt = stmts[i];
            if (stmt.* == .import_from) {
                const base = stmt.import_from;
                if (base.names.len > 0 and std.mem.eql(u8, base.names[0].name, "*")) {
                    try out.append(allocator, stmt);
                    i += 1;
                    continue;
                }
                var j = i;
                var aliases: std.ArrayList(ast.Alias) = .{};
                defer aliases.deinit(allocator);
                while (j < stmts.len and stmts[j].* == .import_from) : (j += 1) {
                    const cur = stmts[j].import_from;
                    if (cur.level != base.level) break;
                    if ((cur.module == null) != (base.module == null)) break;
                    if (cur.module != null and !std.mem.eql(u8, cur.module.?, base.module.?)) break;
                    if (cur.names.len > 0 and std.mem.eql(u8, cur.names[0].name, "*")) break;
                    try aliases.appendSlice(allocator, cur.names);
                }
                var merged = false;
                if (aliases.items.len > 1) {
                    for (groups) |group| {
                        if (group.level != base.level) continue;
                        if ((group.module == null) != (base.module == null)) continue;
                        if (group.module != null and !std.mem.eql(u8, group.module.?, base.module.?)) continue;
                        if (namesMatchGroup(aliases.items, group.names)) {
                            const a = allocator;
                            const names = try a.alloc(ast.Alias, aliases.items.len);
                            std.mem.copyForwards(ast.Alias, names, aliases.items);
                            const merged_stmt = try a.create(Stmt);
                            merged_stmt.* = .{ .import_from = .{
                                .module = base.module,
                                .names = names,
                                .level = base.level,
                            } };
                            try out.append(allocator, merged_stmt);
                            i = j;
                            merged = true;
                            break;
                        }
                    }
                }
                if (merged) continue;
            }

            try out.append(allocator, stmt);
            i += 1;
        }

        return out.toOwnedSlice(allocator);
    }

    fn mergeImportFromGroupsDeep(
        self: *Decompiler,
        allocator: Allocator,
        stmts: []const *Stmt,
    ) DecompileError![]const *Stmt {
        for (stmts) |stmt| {
            switch (stmt.*) {
                .function_def => |*f| {
                    f.body = try self.mergeImportFromGroupsDeep(allocator, f.body);
                },
                .class_def => |*c| {
                    c.body = try self.mergeImportFromGroupsDeep(allocator, c.body);
                },
                .for_stmt => |*f| {
                    f.body = try self.mergeImportFromGroupsDeep(allocator, f.body);
                    f.else_body = try self.mergeImportFromGroupsDeep(allocator, f.else_body);
                },
                .while_stmt => |*w| {
                    w.body = try self.mergeImportFromGroupsDeep(allocator, w.body);
                    w.else_body = try self.mergeImportFromGroupsDeep(allocator, w.else_body);
                },
                .if_stmt => |*i| {
                    i.body = try self.mergeImportFromGroupsDeep(allocator, i.body);
                    i.else_body = try self.mergeImportFromGroupsDeep(allocator, i.else_body);
                },
                .with_stmt => |*w| {
                    w.body = try self.mergeImportFromGroupsDeep(allocator, w.body);
                },
                .try_stmt => |*t| {
                    t.body = try self.mergeImportFromGroupsDeep(allocator, t.body);
                    t.else_body = try self.mergeImportFromGroupsDeep(allocator, t.else_body);
                    t.finalbody = try self.mergeImportFromGroupsDeep(allocator, t.finalbody);
                    if (t.handlers.len > 0) {
                        const handlers = try allocator.alloc(ast.ExceptHandler, t.handlers.len);
                        for (t.handlers, 0..) |h, idx| {
                            handlers[idx] = h;
                            handlers[idx].body = try self.mergeImportFromGroupsDeep(allocator, h.body);
                        }
                        t.handlers = handlers;
                    }
                },
                .match_stmt => |*m| {
                    if (m.cases.len > 0) {
                        const cases = try allocator.alloc(ast.MatchCase, m.cases.len);
                        for (m.cases, 0..) |c, idx| {
                            cases[idx] = c;
                            cases[idx].body = try self.mergeImportFromGroupsDeep(allocator, c.body);
                        }
                        m.cases = cases;
                    }
                },
                else => {},
            }
        }

        return try self.mergeImportFromGroups(allocator, stmts);
    }

    fn reachesBlock(
        self: *Decompiler,
        start: u32,
        target: u32,
        stop: ?u32,
    ) DecompileError!bool {
        if (start == target) return true;
        try self.cond_seen.ensureSize(self.allocator, self.cfg.blocks.len);
        self.cond_seen.reset();
        self.cond_stack.clearRetainingCapacity();
        try self.cond_stack.append(self.allocator, start);

        while (self.cond_stack.items.len > 0) {
            const cur = self.cond_stack.items[self.cond_stack.items.len - 1];
            self.cond_stack.items.len -= 1;
            if (cur >= self.cfg.blocks.len) continue;
            if (self.cond_seen.isSet(cur)) continue;
            try self.cond_seen.set(self.allocator, cur);

            const blk = &self.cfg.blocks[cur];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const next = edge.target;
                if (stop) |stop_id| {
                    if (next == stop_id) continue;
                }
                if (next == target) return true;
                if (!self.cond_seen.isSet(next)) {
                    try self.cond_stack.append(self.allocator, next);
                }
            }
        }
        return false;
    }

    fn findTerminalStmtFrom(
        self: *Decompiler,
        start: u32,
        stop: u32,
    ) DecompileError!?TerminalResult {
        if (start >= self.cfg.blocks.len) return null;
        try self.cond_seen.ensureSize(self.allocator, self.cfg.blocks.len);
        self.cond_seen.reset();
        self.cond_stack.clearRetainingCapacity();
        try self.cond_stack.append(self.allocator, start);

        const a = self.arena.allocator();
        while (self.cond_stack.items.len > 0) {
            const cur = self.cond_stack.items[self.cond_stack.items.len - 1];
            self.cond_stack.items.len -= 1;
            if (cur >= self.cfg.blocks.len) continue;
            if (cur == stop) continue;
            if (self.cond_seen.isSet(cur)) continue;
            try self.cond_seen.set(self.allocator, cur);

            if (self.isTerminalBlock(cur)) {
                var tmp: std.ArrayList(*Stmt) = .{};
                defer tmp.deinit(a);
                try self.decompileBlockIntoWithStackAndSkip(cur, &tmp, a, &.{}, 0);
                if (tmp.items.len == 1 and self.stmtIsTerminal(tmp.items[0])) {
                    return .{ .block_id = cur, .stmt = tmp.items[0] };
                }
            }

            const blk = &self.cfg.blocks[cur];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const next = edge.target;
                if (next == stop) continue;
                if (!self.cond_seen.isSet(next)) {
                    try self.cond_stack.append(self.allocator, next);
                }
            }
        }

        return null;
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

        var expr: *Expr = undefined;
        var extra = false;
        if (block_id == first_block) {
            expr = first_expr;
        } else {
            const eval = (try self.evalCondBlock(block_id, base_vals, cond_kind)) orelse return null;
            expr = eval.expr;
            extra = eval.extra;
        }

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

        var t_id = true_id.?;
        var f_id = false_id.?;
        if (extra) {
            const false_target = stop_false orelse false_block;
            if (try self.tryChainCond(expr, t_id, f_id, false_target)) |chain| {
                expr = chain.expr;
                t_id = chain.t_id;
                f_id = chain.f_id;
            } else {
                return null;
            }
        }
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
        if (self.pending_vals) |vals| {
            deinitStackValuesSlice(self.allocator, self.allocator, vals);
            self.pending_vals = null;
        }
        if (base_vals.len > 0) {
            self.pending_vals = base_vals;
            if (base_owned.*) base_owned.* = false;
        } else if (base_owned.*) {
            deinitStackValuesSlice(self.allocator, self.allocator, base_vals);
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
        stmts_allocator: Allocator,
    ) DecompileError!?u32 {
        const pattern = (try self.findTernaryLeaf(block_id, limit)) orelse return null;

        const stmts_len = stmts.items.len;
        const cond_res = (try self.initCondSim(block_id, stmts, stmts_allocator)) orelse {
            stmts.items.len = stmts_len;
            return null;
        };
        const base_vals = cond_res.base_vals;
        var base_owned = true;
        defer if (base_owned) deinitStackValuesSlice(self.allocator, self.allocator, base_vals);

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

        const true_expr = (try self.simulateTernaryBranch(pattern.true_block, base_vals)) orelse {
            stmts.items.len = stmts_len;
            return null;
        };
        const false_expr = (try self.simulateTernaryBranch(pattern.false_block, base_vals)) orelse {
            stmts.items.len = stmts_len;
            return null;
        };

        try self.saveTernary(condition, true_expr, false_expr, base_vals, &base_owned);
        return pattern.merge_block;
    }

    fn tryDecompileTernaryInto(
        self: *Decompiler,
        block_id: u32,
        limit: u32,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
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
                    deinitStackValuesSlice(self.allocator, self.allocator, base_vals);
                }
            }

            const stmts_len = stmts.items.len;
            const cond_res = (try self.initCondSim(chain.condition_blocks[0], stmts, stmts_allocator)) orelse {
                stmts.items.len = stmts_len;
                return null;
            };
            try cond_list.append(self.allocator, cond_res.expr);
            base_vals = cond_res.base_vals;
            base_owned = true;

            if (chain.condition_blocks.len > 1) {
                for (chain.condition_blocks[1..]) |cond_id| {
                    const cond_opt = try self.simulateConditionExpr(cond_id, base_vals);
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

            const true_opt = try self.simulateTernaryBranch(chain.true_block, base_vals);
            if (true_opt == null) {
                stmts.items.len = stmts_len;
                return null;
            }
            true_expr = true_opt.?;

            const false_opt = try self.simulateTernaryBranch(chain.false_block, base_vals);
            if (false_opt == null) {
                stmts.items.len = stmts_len;
                return null;
            }
            false_expr = false_opt.?;

            try self.saveTernary(condition, true_expr, false_expr, base_vals, &base_owned);
            return chain.merge_block;
        }

        if (try self.tryDecompileTernaryTreeInto(block_id, limit, stmts, stmts_allocator)) |next_block| {
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
                deinitStackValuesSlice(self.allocator, self.allocator, base_vals);
            }
        }

        const stmts_len = stmts.items.len;
        const cond_res = (try self.initCondSim(pattern.condition_block, stmts, stmts_allocator)) orelse {
            stmts.items.len = stmts_len;
            return null;
        };
        const condition = cond_res.expr;
        base_vals = cond_res.base_vals;
        base_owned = true;

        const true_opt = try self.simulateTernaryBranch(pattern.true_block, base_vals);
        if (true_opt == null) {
            stmts.items.len = stmts_len;
            return null;
        }
        true_expr = true_opt.?;

        const false_opt = try self.simulateTernaryBranch(pattern.false_block, base_vals);
        if (false_opt == null) {
            stmts.items.len = stmts_len;
            return null;
        }
        false_expr = false_opt.?;

        try self.saveTernary(condition, true_expr, false_expr, base_vals, &base_owned);
        return pattern.merge_block;
    }

    fn loopHasCompAdd(self: *Decompiler, pattern: ctrl.ForPattern) DecompileError!bool {
        try self.cond_seen.ensureSize(self.allocator, self.cfg.blocks.len);
        self.cond_seen.reset();
        self.cond_stack.clearRetainingCapacity();
        try self.cond_stack.append(self.allocator, pattern.body_block);

        while (self.cond_stack.items.len > 0) {
            const cur = self.cond_stack.items[self.cond_stack.items.len - 1];
            self.cond_stack.items.len -= 1;
            if (cur >= self.cfg.blocks.len) continue;
            if (cur == pattern.exit_block or cur == pattern.header_block) continue;
            if (self.cond_seen.isSet(cur)) continue;
            try self.cond_seen.set(self.allocator, cur);

            const blk = &self.cfg.blocks[cur];
            for (blk.instructions) |inst| {
                if (inst.opcode == .LIST_APPEND or inst.opcode == .SET_ADD or inst.opcode == .MAP_ADD) {
                    return true;
                }
            }
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const next = edge.target;
                if (next == pattern.exit_block or next == pattern.header_block) continue;
                if (self.cond_seen.isSet(next)) continue;
                try self.cond_stack.append(self.allocator, next);
            }
        }

        return false;
    }

    const CondEval = struct {
        expr: *Expr,
        extra: bool,
    };

    fn evalCondBlock(
        self: *Decompiler,
        block_id: u32,
        base_vals: []const StackValue,
        cond_kind: ?ctrl.BoolOpKind,
    ) DecompileError!?CondEval {
        if (block_id >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[block_id];

        var skip: usize = 0;
        if (cond_kind) |kind| {
            skip = self.boolOpBlockSkip(block, kind);
        }
        if (skip > block.instructions.len) return null;

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (base_vals) |val| {
            try sim.stack.push(try sim.cloneStackValue(val));
        }

        for (block.instructions[skip..], 0..) |inst, rel_idx| {
            const idx = skip + rel_idx;
            if (cond_kind) |kind| {
                if (kind == .pop_top) {
                    if (idx + 2 < block.instructions.len and
                        inst.opcode == .COPY and inst.arg == 1 and
                        block.instructions[idx + 1].opcode == .TO_BOOL and
                        ctrl.Analyzer.isConditionalJump(undefined, block.instructions[idx + 2].opcode))
                    {
                        break;
                    }
                }
            }
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (isStatementOpcode(inst.opcode)) return null;
            if (!try simOpt(&sim, inst)) return null;
        }

        const expr = (try popExprOpt(&sim)) orelse return null;
        if (sim.stack.len() == base_vals.len) return .{ .expr = expr, .extra = false };
        if (sim.stack.len() == base_vals.len + 1) return .{ .expr = expr, .extra = true };
        return null;
    }

    const ChainCond = struct {
        expr: *Expr,
        t_id: u32,
        f_id: u32,
    };

    fn tryChainCond(
        self: *Decompiler,
        expr: *Expr,
        t_id: u32,
        f_id: u32,
        false_target: u32,
    ) DecompileError!?ChainCond {
        if (expr.* != .compare) return null;
        const cmp1 = expr.compare;
        if (cmp1.comparators.len == 0) return null;
        if (self.resolveJumpOnlyBlock(f_id) != false_target) return null;
        if (t_id >= self.cfg.blocks.len) return null;

        const then_blk = &self.cfg.blocks[t_id];
        if (condBlockHasPrelude(then_blk)) return null;
        const then_term = then_blk.terminator() orelse return null;
        if (!ctrl.Analyzer.isConditionalJump(undefined, then_term.opcode)) return null;

        var t2_id: ?u32 = null;
        var f2_id: ?u32 = null;
        for (then_blk.successors) |edge| {
            if (edge.edge_type == .exception) continue;
            if (edge.edge_type == .conditional_false) {
                f2_id = edge.target;
            } else if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                t2_id = edge.target;
            }
        }
        if (t2_id == null or f2_id == null) return null;
        if (self.resolveJumpOnlyBlock(f2_id.?) != false_target) return null;

        const mid = cmp1.comparators[cmp1.comparators.len - 1];
        var then_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer then_sim.deinit();
        then_sim.lenient = true;
        then_sim.stack.allow_underflow = true;

        const mid_val: StackValue = .{ .expr = mid };
        try then_sim.stack.push(try then_sim.cloneStackValue(mid_val));

        const cond2 = (try self.condExprFromBlock(t_id, &then_sim, t2_id.?, f2_id.?, 0)) orelse return null;
        if (cond2.* != .compare) return null;
        if (!ast.exprEqual(mid, cond2.compare.left)) return null;

        const merged = (try self.mergeCompareChain(expr, cond2)) orelse return null;
        return .{
            .expr = merged,
            .t_id = self.resolveJumpOnlyBlock(t2_id.?),
            .f_id = self.resolveJumpOnlyBlock(f2_id.?),
        };
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
        if (!try self.loopHasCompAdd(pattern)) return null;

        // Find GET_ITER position
        var get_iter_offset: ?u32 = null;
        for (setup.instructions) |inst| {
            if (inst.opcode == .GET_ITER) {
                get_iter_offset = inst.offset;
                break;
            }
        }

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
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
                var setup_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
                defer setup_sim.deinit();

                var setup_iter = decoder.InstructionIterator.init(self.code.code, self.version);
                while (setup_iter.next()) |inst| {
                    if (inst.offset >= gio) break;
                    if (inst.opcode == .RESUME) continue;
                    if (!try simOpt(&setup_sim, inst)) return null;
                }

                // Get the iterator expression from TOS
                if (setup_sim.stack.pop()) |val| {
                    switch (val) {
                        .expr => |e| try sim.stack.push(.{ .expr = e }),
                        else => {
                            const iter_placeholder = try self.makeName(".iter", .load);
                            try sim.stack.push(.{ .expr = iter_placeholder });
                        },
                    }
                } else {
                    const iter_placeholder = try self.makeName(".iter", .load);
                    try sim.stack.push(.{ .expr = iter_placeholder });
                }
                sim_start = gio;
            }
        }

        var iter = decoder.InstructionIterator.init(self.code.code, self.version);
        while (iter.next()) |inst| {
            if (inst.offset < sim_start) continue;
            if (inst.offset >= exit_offset) break;
            if (!try simOpt(&sim, inst)) return null;
        }

        const expr = sim.buildInlineCompExpr() catch |err| {
            if (isSoftSimErr(err)) return null;
            return err;
        } orelse return null;

        if (self.pending_ternary_expr != null) return error.InvalidBlock;
        self.pending_ternary_expr = expr;

        const stack_copy = try self.cloneStackValues(sim.stack.items.items);
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
            .else_block = null,
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
            defer deinitStackValuesSlice(self.allocator, self.allocator, result.stack);
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

    fn tryDecompileAndOrInto(
        self: *Decompiler,
        block_id: u32,
        limit: u32,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
    ) DecompileError!?u32 {
        if (self.pending_ternary_expr != null or self.pending_store_expr != null or self.pending_vals != null) {
            return null;
        }
        const pattern = self.analyzer.detectAndOr(block_id) orelse return null;
        if (pattern.true_block >= limit or pattern.false_block >= limit or pattern.merge_block >= limit) {
            return null;
        }
        if (pattern.merge_block <= block_id) return null;

        const stmts_len = stmts.items.len;
        const cond_res = (try self.initCondSim(pattern.condition_block, stmts, stmts_allocator)) orelse {
            stmts.items.len = stmts_len;
            return null;
        };
        const base_vals = cond_res.base_vals;
        var base_owned = true;
        defer if (base_owned) deinitStackValuesSlice(self.allocator, self.allocator, base_vals);

        const true_blk = &self.cfg.blocks[pattern.true_block];
        const false_blk = &self.cfg.blocks[pattern.false_block];
        const true_skip = self.boolOpBlockSkip(true_blk, .or_pop);
        const false_skip = self.boolOpBlockSkip(false_blk, .or_pop);

        const true_expr = (try self.simulateValueExprSkip(pattern.true_block, base_vals, true_skip)) orelse {
            stmts.items.len = stmts_len;
            return null;
        };
        const false_expr = (try self.simulateValueExprSkip(pattern.false_block, base_vals, false_skip)) orelse {
            stmts.items.len = stmts_len;
            return null;
        };

        const and_expr = try self.makeBoolPair(cond_res.expr, true_expr, .and_);
        const or_expr = try self.makeBoolPair(and_expr, false_expr, .or_);

        const merge_block = &self.cfg.blocks[pattern.merge_block];
        if (merge_block.terminator()) |mt| {
            if (ctrl.Analyzer.isConditionalJump(undefined, mt.opcode)) {
                if (self.pending_ternary_expr != null or self.pending_store_expr != null) return null;
                self.pending_store_expr = or_expr;
                if (base_vals.len > 0) {
                    if (self.pending_vals) |vals| {
                        deinitStackValuesSlice(self.allocator, self.allocator, vals);
                    }
                    self.pending_vals = base_vals;
                    base_owned = false;
                }
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
                    return null;
                },
                else => return err,
            }
        };

        return pattern.merge_block + 1;
    }

    /// Try to decompile a short-circuit boolean expression (x and y, x or y).
    fn tryDecompileBoolOpInto(
        self: *Decompiler,
        block_id: u32,
        limit: u32,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
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
        var skip_first_store = false;
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
                    if (err == error.OutOfMemory) return err;
                    return null;
                };
            }
        } else {
            // Simulate condition block up to conditional jump
            for (cond_block.instructions) |inst| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                cond_sim.simulate(inst) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return null;
                };
            }
        }

        // First operand is on stack
        const first = cond_sim.stack.popExpr() catch |err| {
            if (err == error.OutOfMemory) return err;
            return null;
        };

        const base_vals = try self.cloneStackValues(cond_sim.stack.items.items);
        defer deinitStackValuesSlice(self.allocator, self.allocator, base_vals);

        // Build potentially nested BoolOp expression
        const bool_result = self.buildBoolOpExpr(first, pattern, base_vals) catch |err| {
            if (err == error.InvalidBlock) return null;
            return err;
        };
        const bool_expr = bool_result.expr;
        const final_merge = bool_result.merge_block;

        // Process merge block with the bool expression on stack
        const merge_block = &self.cfg.blocks[final_merge];
        if (merge_block.terminator()) |mt| {
            if (ctrl.Analyzer.isConditionalJump(undefined, mt.opcode)) {
                if (self.pending_ternary_expr != null or self.pending_store_expr != null) return error.InvalidBlock;
                self.pending_store_expr = bool_expr;
                return final_merge;
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
                error.StackUnderflow, error.NotAnExpression, error.InvalidBlock => return null,
                else => return err,
            }
        };

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
        if (pattern.merge_block) |merge| {
            if (merge > pattern.condition_block and merge != pattern.then_block and
                (pattern.else_block == null or merge != pattern.else_block.?))
            {
                return merge;
            }
        }

        var end = try self.branchEnd(pattern.then_block, null);
        if (pattern.else_block) |else_id| {
            if (pattern.is_elif) {
                const else_pattern = try self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    end = @max(end, try self.findIfChainEnd(else_pattern.if_stmt));
                } else {
                    end = @max(end, try self.branchEnd(else_id, null));
                }
            } else {
                end = @max(end, try self.branchEnd(else_id, null));
            }
        }

        return end;
    }

    fn needsPredecessorSeed(self: *Decompiler, block: *const BasicBlock) bool {
        _ = self;
        const term = block.terminator();
        if (term != null and term.?.opcode == .FOR_LOOP) return true;
        if (block.instructions.len > 0) {
            const first = block.instructions[0].opcode;
            return switch (first) {
                .SEND,
                .YIELD_VALUE,
                .STORE_FAST,
                .STORE_NAME,
                .STORE_GLOBAL,
                .STORE_ATTR,
                .STORE_SUBSCR,
                .POP_TOP,
                .ROT_TWO,
                .ROT_THREE,
                .ROT_FOUR,
                .DUP_TOP,
                .DUP_TOP_TWO,
                .COPY,
                .SWAP,
                .BINARY_OP,
                .COMPARE_OP,
                .CALL,
                .BUILD_TUPLE,
                .BUILD_LIST,
                .BUILD_MAP,
                .BUILD_SET,
                .UNPACK_SEQUENCE,
                .RETURN_VALUE,
                .END_SEND,
                => true,
                else => false,
            };
        }
        return false;
    }

    fn seedFromPredecessors(self: *Decompiler, block_id: u32, sim: *SimContext) DecompileError!void {
        const prev_lenient = sim.lenient;
        const prev_underflow = sim.stack.allow_underflow;
        defer {
            sim.lenient = prev_lenient;
            sim.stack.allow_underflow = prev_underflow;
        }
        sim.lenient = true;
        sim.stack.allow_underflow = true;

        // Recursively find the chain of fall-through predecessors
        // and simulate them to build up stack state.
        var cur_id = block_id;
        var to_simulate: [16]u32 = undefined;
        var sim_count: usize = 0;
        while (sim_count < to_simulate.len) {
            var found_pred: ?u32 = null;
            const cur_block = &self.cfg.blocks[cur_id];
            for (cur_block.predecessors) |pred_id| {
                if (pred_id < cur_id) {
                    found_pred = pred_id;
                    break;
                }
            }
            if (found_pred) |pid| {
                to_simulate[sim_count] = pid;
                sim_count += 1;
                cur_id = pid;
            } else break;
        }

        // Simulate from oldest predecessor to newest.
        var i = sim_count;
        while (i > 0) {
            i -= 1;
            const pred = &self.cfg.blocks[to_simulate[i]];
            for (pred.instructions) |inst| {
                if (inst.opcode == .NOT_TAKEN) continue;
                if (inst.isUnconditionalJump()) break;
                try sim.simulate(inst);
                if (inst.isConditionalJump()) break;
            }
        }
    }

    /// Decompile the code object into a list of statements.
    pub fn decompile(self: *Decompiler) DecompileError![]const *Stmt {
        if (self.cfg.blocks.len == 0) {
            try self.insertModuleGlobals();
            return self.statements.items;
        }

        // Process blocks in order, using control flow patterns
        var block_idx: u32 = 0;
        while (block_idx < self.cfg.blocks.len) {
            const prev_idx = block_idx;
            if (self.consumed.isSet(block_idx)) {
                block_idx += 1;
                continue;
            }
            if (block_idx != self.cfg.entry and self.cfg.blocks[block_idx].predecessors.len == 0) {
                block_idx += 1;
                continue;
            }
            // Try BoolOp pattern first (x and y, x or y)
            if (try self.tryDecompileBoolOpInto(
                block_idx,
                @intCast(self.cfg.blocks.len),
                &self.statements,
                self.allocator,
            )) |next_block| {
                block_idx = next_block;
                if (block_idx <= prev_idx) {
                    if (self.last_error_ctx == null) {
                        self.last_error_ctx = .{
                            .code_name = self.code.name,
                            .block_id = prev_idx,
                            .offset = self.cfg.blocks[prev_idx].start_offset,
                            .opcode = "boolop_no_progress",
                        };
                    }
                    return error.InvalidBlock;
                }
                continue;
            }
            if (try self.tryDecompileTernaryInto(
                block_idx,
                @intCast(self.cfg.blocks.len),
                &self.statements,
                self.allocator,
            )) |next_block| {
                block_idx = next_block;
                if (block_idx <= prev_idx) {
                    if (self.last_error_ctx == null) {
                        self.last_error_ctx = .{
                            .code_name = self.code.name,
                            .block_id = prev_idx,
                            .offset = self.cfg.blocks[prev_idx].start_offset,
                            .opcode = "ternary_no_progress",
                        };
                    }
                    return error.InvalidBlock;
                }
                continue;
            }
            if (try self.tryDecompileAndOrInto(
                block_idx,
                @intCast(self.cfg.blocks.len),
                &self.statements,
                self.allocator,
            )) |next_block| {
                block_idx = next_block;
                if (block_idx <= prev_idx) {
                    if (self.last_error_ctx == null) {
                        self.last_error_ctx = .{
                            .code_name = self.code.name,
                            .block_id = prev_idx,
                            .offset = self.cfg.blocks[prev_idx].start_offset,
                            .opcode = "and_or_no_progress",
                        };
                    }
                    return error.InvalidBlock;
                }
                continue;
            }
            const pattern = try self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    var skip_first_store = false;
                    try self.processPartialBlock(&self.cfg.blocks[p.condition_block], &self.statements, self.allocator, &skip_first_store, null);
                    const stmt = try self.decompileIf(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    // Skip all processed blocks - use chained comparison override if set
                    if (self.if_next) |next| {
                        block_idx = next;
                        self.if_next = null;
                        self.chained_cmp_next_block = null;
                    } else if (self.chained_cmp_next_block) |chain_next| {
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
                    if (self.loop_next) |next| {
                        block_idx = next;
                        self.loop_next = null;
                    } else {
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
                            defer self.arena.allocator().free(exit_stmts);
                            try self.statements.appendSlice(self.allocator, exit_stmts);
                            block_idx = p.exit_block + 1;
                        } else {
                            block_idx = p.exit_block;
                        }
                    }
                },
                .for_loop => |p| {
                    if (try self.tryDecompileInlineListComp(p)) |result| {
                        deinitStackValuesSlice(self.allocator, self.allocator, result.stack);
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
                    try self.emitMatchPrelude(p.subject_block, &self.statements, self.allocator);
                    const result = try self.decompileMatch(p);
                    if (result.stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                else => {
                    const block = &self.cfg.blocks[block_idx];
                    if (block.is_loop_header) {
                        if (try self.decompileLoopHeader(block_idx)) |result| {
                            if (result.stmt) |s| {
                                try self.statements.append(self.allocator, s);
                            }
                            block_idx = result.next_block;
                            break;
                        }
                    }
                    // Skip exception handler blocks - they're decompiled as part of try/except
                    if (block.is_exception_handler or self.hasExceptionHandlerOpcodes(block)) {
                        block_idx += 1;
                        continue;
                    }
                    // Skip exception table infrastructure blocks
                    const term = block.terminator();
                    if (term != null and term.?.opcode == .POP_JUMP_FORWARD_IF_NOT_NONE) {
                        block_idx += 1;
                        continue;
                    }
                    // Process block as sequential statements
                    try self.decompileBlock(block_idx);
                    block_idx += 1;
                },
            }
            if (block_idx <= prev_idx) {
                if (self.last_error_ctx == null) {
                    self.last_error_ctx = .{
                        .code_name = self.code.name,
                        .block_id = prev_idx,
                        .offset = self.cfg.blocks[prev_idx].start_offset,
                        .opcode = "decompile_no_progress",
                    };
                }
                return error.InvalidBlock;
            }
        }

        try self.insertModuleGlobals();
        return self.statements.items;
    }

    fn insertModuleGlobals(self: *Decompiler) DecompileError!void {
        _ = self;
    }

    /// Decompile a single basic block into statements.
    fn decompileBlock(self: *Decompiler, block_id: u32) DecompileError!void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        if (self.hasExceptionSuccessor(block) or self.hasWithExitCleanup(block)) {
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }

        const exc_count = self.exceptionSeedCount(block_id, block);
        if (exc_count > 0) {
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }
        const seed = if (block_id < self.stack_in.len) blk: {
            if (self.stack_in[block_id]) |entry| break :blk entry;
            break :blk &.{};
        } else &.{};

        if (seed.len > 0) {
            for (seed) |val| {
                const cloned = try sim.cloneStackValue(val);
                try sim.stack.push(cloned);
            }
        }
        if (exc_count > 0) {
            for (0..exc_count) |_| {
                const placeholder = try self.arena.allocator().create(Expr);
                placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                try sim.stack.push(.{ .expr = placeholder });
            }
        }

        // Inherit stack from fall-through predecessor if needed
        const needs_predecessor = self.needsPredecessorSeed(block);

        if (exc_count == 0 and seed.len == 0 and needs_predecessor) {
            try self.seedFromPredecessors(block_id, &sim);
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }

        try self.processBlockWithSim(block, &sim, &self.statements, self.allocator);
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

        try self.decompileBlockIntoWithStackAndSkip(start_block, &stmts, a, init_stack, skip_first);

        if (start_block + 1 < limit) {
            const rest = try self.decompileStructuredRange(start_block + 1, limit);
            try stmts.appendSlice(a, rest);
        }

        return stmts.toOwnedSlice(a);
    }

    /// Decompile a single block's statements into the provided list.
    fn decompileBlockInto(self: *Decompiler, block_id: u32, stmts: *std.ArrayList(*Stmt), stmts_allocator: Allocator) DecompileError!void {
        return self.decompileBlockIntoWithStack(block_id, stmts, stmts_allocator, &.{});
    }

    /// Decompile a single block with initial stack values.
    fn decompileBlockIntoWithStack(
        self: *Decompiler,
        block_id: u32,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
        init_stack: []const StackValue,
    ) DecompileError!void {
        return self.decompileBlockIntoWithStackAndSkip(block_id, stmts, stmts_allocator, init_stack, 0);
    }

    /// Decompile a single block, optionally skipping first N instructions.
    fn decompileBlockIntoWithStackAndSkip(
        self: *Decompiler,
        block_id: u32,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
        init_stack: []const StackValue,
        skip_first: usize,
    ) DecompileError!void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        if (self.hasExceptionSuccessor(block) or self.hasWithExitCleanup(block)) {
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }

        const seed = if (init_stack.len > 0)
            init_stack
        else blk: {
            if (block_id < self.stack_in.len) {
                if (self.stack_in[block_id]) |entry| break :blk entry;
            }
            break :blk &.{};
        };

        const exc_count = self.exceptionSeedCount(block_id, block);
        if (exc_count > 0) {
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }
        var seed_all_unknown = true;
        if (seed.len > 0) {
            for (seed) |val| {
                if (val != .unknown) {
                    seed_all_unknown = false;
                    break;
                }
            }
        }
        if (self.needsPredecessorSeed(block) and (seed.len == 0 or seed_all_unknown)) {
            try self.seedFromPredecessors(block_id, &sim);
        } else if (seed.len > 0) {
            sim.stack.allow_underflow = true;
            for (seed) |val| {
                const cloned = try sim.cloneStackValue(val);
                try sim.stack.push(cloned);
            }
        }
        if (exc_count > 0) {
            for (0..exc_count) |_| {
                const placeholder = try self.arena.allocator().create(Expr);
                placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                try sim.stack.push(.{ .expr = placeholder });
            }
        }

        const needs_predecessor = self.needsPredecessorSeed(block);
        if (exc_count == 0 and seed.len == 0 and needs_predecessor) {
            try self.seedFromPredecessors(block_id, &sim);
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }

        try self.processBlockWithSimAndSkip(block, &sim, stmts, stmts_allocator, skip_first);
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

        // Check if then-block starts with POP_TOP (chained comparison pattern)
        const then_block = &self.cfg.blocks[pattern.then_block];
        if (then_block.instructions.len < 3) return null;
        var pop_idx: usize = 0;
        if (then_block.instructions[0].opcode == .NOT_TAKEN) {
            if (then_block.instructions.len < 4) return null;
            pop_idx = 1;
        }
        if (then_block.instructions[pop_idx].opcode != .POP_TOP) return null;

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
            var then_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
            defer then_sim.deinit();
            try then_sim.stack.push(.{ .expr = current_mid });

            // Simulate instructions from after POP_TOP to compare (inclusive)
            for (blk.instructions[sim_start .. cmp_idx + 1]) |inst| {
                try then_sim.simulate(inst);
            }

            const cmp_expr = try then_sim.stack.popExpr();
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
                current_mid = try then_sim.stack.popExpr();
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
            var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
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
        if (self.if_in_progress) |*set| {
            if (set.isSet(pattern.condition_block)) return null;
            set.set(pattern.condition_block);
            defer set.unset(pattern.condition_block);
        }
        const cond_block = &self.cfg.blocks[pattern.condition_block];

        // Get the condition expression from the last instruction before the jump
        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        if (pattern.condition_block < self.stack_in.len) {
            if (self.stack_in[pattern.condition_block]) |entry| {
                for (entry) |val| {
                    const cloned = try sim.cloneStackValue(val);
                    try sim.stack.push(cloned);
                }
            }
        }

        // Check if terminator is Python 3.0 style JUMP_IF_FALSE/TRUE
        // These don't pop the condition, so branches start with POP_TOP
        const term = cond_block.terminator();
        const legacy_cond = if (term) |t| t.opcode == .JUMP_IF_FALSE or t.opcode == .JUMP_IF_TRUE else false;

        // Simulate up to but not including the conditional jump, skipping first N instructions
        for (cond_block.instructions[skip_cond..]) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            try sim.simulate(inst);
        }

        var condition = try sim.stack.popExpr();
        var then_block = pattern.then_block;
        var else_block = pattern.else_block;
        var is_elif = pattern.is_elif;
        var forced_then_end: ?u32 = null;
        if (is_elif) {
            if (else_block) |else_id| {
                if (self.analyzer.detectBoolOp(else_id)) |bool_pat| {
                    if (self.isExprOnlyBlock(bool_pat.second_block)) {
                        is_elif = false;
                    }
                }
                if (is_elif and try self.reachesBlock(else_id, then_block, pattern.condition_block) and
                    try self.postDominates(then_block, else_id))
                {
                    condition = try self.invertConditionExpr(condition);
                    try self.emitDecisionTrace(pattern.condition_block, "if_invert_elif_merge", condition);
                    const merge = then_block;
                    then_block = else_id;
                    else_block = null;
                    is_elif = false;
                    self.if_next = merge;
                    forced_then_end = merge;
                }
            }
        }
        const merge_forward = if (pattern.merge_block) |merge| merge > pattern.condition_block else false;
        const merge_else = !is_elif and merge_forward and pattern.merge_block != null and pattern.merge_block == pattern.else_block;
        const orig_then = then_block;
        const orig_else = else_block;
        const orig_else_forward = if (orig_else) |eid| eid > pattern.condition_block else false;
        const orig_then_reaches_else = if (orig_else_forward)
            try self.reachesBlock(orig_then, orig_else.?, pattern.condition_block)
        else
            false;

        if (!is_elif) {
            if (pattern.merge_block) |merge| {
                if (merge_forward) {
                    if (else_block) |else_id| {
                        if (merge == else_id) {
                            const else_term = self.isTerminalBlock(else_id);
                            if (!else_term) {
                                else_block = null;
                                self.if_next = merge;
                            }
                        }
                    }
                }
            }
            if (orig_then_reaches_else) {
                if (orig_else) |else_id| {
                    if (else_id > orig_then and try self.postDominates(else_id, orig_then)) {
                        self.if_next = else_id;
                    }
                }
            }
        }

        var swapped_true_jump = false;
        if (!is_elif and !legacy_cond) {
            if (term) |t| switch (t.opcode) {
                .POP_JUMP_IF_TRUE,
                .POP_JUMP_FORWARD_IF_TRUE,
                .POP_JUMP_BACKWARD_IF_TRUE,
                .JUMP_IF_TRUE,
                => {
                    if (else_block) |else_id| {
                        var cond_jump_count: usize = 0;
                        var has_call = false;
                        var has_cmp = false;
                        for (cond_block.instructions) |inst| {
                            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) cond_jump_count += 1;
                            switch (inst.opcode) {
                                .CALL_FUNCTION,
                                .CALL_METHOD,
                                .CALL_FUNCTION_KW,
                                .CALL_FUNCTION_EX,
                                .CALL,
                                => has_call = true,
                                .COMPARE_OP,
                                .CONTAINS_OP,
                                .IS_OP,
                                => has_cmp = true,
                                else => {},
                            }
                        }
                        if (cond_jump_count <= 1 and self.analyzer.detectBoolOp(pattern.condition_block) == null) {
                            const is_not = condition.* == .unary_op and condition.unary_op.op == .not_;
                            const can_invert = has_call and !has_cmp;
                            if (can_invert and !is_not) {
                                condition = try self.invertConditionExpr(condition);
                                try self.emitDecisionTrace(pattern.condition_block, "if_invert_true_jump", condition);
                                const tmp = then_block;
                                then_block = else_id;
                                else_block = tmp;
                                is_elif = false;
                                swapped_true_jump = true;
                            }
                        }
                    }
                },
                else => {},
            };
        }

        // Check for chained comparison pattern (Python 3.14+)
        if (try self.tryDecompileChainedComparison(pattern, condition, &sim)) |chain_result| {
            // condition's parts have been transferred to chain_result.stmt, don't deinit
            self.chained_cmp_next_block = chain_result.next_block;
            return chain_result.stmt;
        }
        self.chained_cmp_next_block = null;

        var chain_else: ?u32 = null;
        if (!is_elif) {
            if (else_block) |else_id| {
                if (self.jumpTargetIfJumpOnly(else_id, true)) |target| {
                    chain_else = target;
                }
            }
        }

        // Save remaining stack values to transfer to branches
        var base_vals_buf = try self.cloneStackValues(sim.stack.items.items);
        var base_vals = base_vals_buf;
        var base_owned = true;
        errdefer if (base_owned) {
            deinitStackValuesSlice(self.allocator, self.allocator, base_vals_buf);
        };

        // Collapse chained condition blocks on the then-path (x and y and z).
        var chained_cmp = false;
        var else_resolved = false;
        var cond_chain_then = false;
        if (chain_else != null and condition.* == .compare) {
            const else_target = chain_else.?;
            if (then_block < self.cfg.blocks.len) {
                const then_blk = &self.cfg.blocks[then_block];
                if (!condBlockHasPrelude(then_blk)) {
                    if (then_blk.terminator()) |then_term| {
                        if (ctrl.Analyzer.isConditionalJump(undefined, then_term.opcode)) {
                            var t_id: ?u32 = null;
                            var f_id: ?u32 = null;
                            for (then_blk.successors) |edge| {
                                if (edge.edge_type == .exception) continue;
                                if (edge.edge_type == .conditional_false) {
                                    f_id = edge.target;
                                } else if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                                    t_id = edge.target;
                                }
                            }
                            if (t_id != null and f_id != null and self.resolveJumpOnlyBlock(f_id.?) == else_target) {
                                const cmp1 = condition.compare;
                                if (cmp1.comparators.len > 0) {
                                    const mid = cmp1.comparators[cmp1.comparators.len - 1];
                                    var then_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
                                    defer then_sim.deinit();
                                    then_sim.lenient = true;
                                    then_sim.stack.allow_underflow = true;
                                    try then_sim.stack.push(.{ .expr = mid });
                                    if (try self.condExprFromBlock(then_block, &then_sim, t_id.?, f_id.?, 0)) |cond2| {
                                        if (cond2.* == .compare and ast.exprEqual(mid, cond2.compare.left)) {
                                            const cmp2 = cond2.compare;
                                            const a = self.arena.allocator();
                                            const ops = try a.alloc(ast.CmpOp, cmp1.ops.len + cmp2.ops.len);
                                            const comparators = try a.alloc(*Expr, cmp1.comparators.len + cmp2.comparators.len);
                                            std.mem.copyForwards(ast.CmpOp, ops[0..cmp1.ops.len], cmp1.ops);
                                            std.mem.copyForwards(ast.CmpOp, ops[cmp1.ops.len..], cmp2.ops);
                                            std.mem.copyForwards(*Expr, comparators[0..cmp1.comparators.len], cmp1.comparators);
                                            std.mem.copyForwards(*Expr, comparators[cmp1.comparators.len..], cmp2.comparators);
                                            const chain_expr = try a.create(Expr);
                                            chain_expr.* = .{ .compare = .{
                                                .left = cmp1.left,
                                                .ops = ops,
                                                .comparators = comparators,
                                            } };
                                            condition = chain_expr;
                                            then_block = self.resolveJumpOnlyBlock(t_id.?);
                                            else_block = else_target;
                                            is_elif = false;
                                            chained_cmp = true;
                                            else_resolved = true;
                                            if (base_vals.len > 0) {
                                                const last_idx = base_vals.len - 1;
                                                const last = base_vals_buf[last_idx];
                                                last.deinit(self.allocator, self.allocator);
                                                base_vals_buf[last_idx] = .unknown;
                                                base_vals = base_vals_buf[0..last_idx];
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (!chained_cmp) {
            const cond_else = blk: {
                if (else_block) |else_id| break :blk else_id;
                if (!is_elif and merge_forward) {
                    if (pattern.merge_block) |merge_id| break :blk merge_id;
                }
                break :blk null;
            };
            if (cond_else) |else_id| {
                var seen = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
                defer seen.deinit();
                const else_res = self.resolveJumpOnlyBlock(else_id);
                var cur = then_block;
                var final_then = then_block;
                var progressed = false;
                while (cur < self.cfg.blocks.len) {
                    if (seen.isSet(cur)) break;
                    seen.set(cur);
                    const blk = &self.cfg.blocks[cur];
                    const blk_term = blk.terminator() orelse break;
                    if (!ctrl.Analyzer.isConditionalJump(undefined, blk_term.opcode)) break;
                    if (condBlockHasPrelude(blk)) break;
                    var t_id: ?u32 = null;
                    var f_id: ?u32 = null;
                    for (blk.successors) |edge| {
                        if (edge.edge_type == .exception) continue;
                        if (edge.edge_type == .conditional_false) {
                            f_id = edge.target;
                        } else if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                            t_id = edge.target;
                        }
                    }
                    if (t_id == null or f_id == null) break;
                    if (self.resolveJumpOnlyBlock(f_id.?) != else_res) break;
                    if (t_id.? == else_id) break;
                    progressed = true;
                    final_then = self.resolveJumpOnlyBlock(t_id.?);
                    cur = t_id.?;
                }
                if (progressed and final_then != then_block) {
                    var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
                    defer in_stack.deinit();
                    var memo: std.AutoHashMapUnmanaged(u32, *Expr) = .{};
                    defer memo.deinit(self.allocator);
                    if (try self.buildCondTree(
                        pattern.condition_block,
                        pattern.condition_block,
                        condition,
                        final_then,
                        else_id,
                        base_vals,
                        null,
                        null,
                        &in_stack,
                        &memo,
                    )) |expr| {
                        condition = expr;
                        then_block = final_then;
                        cond_chain_then = true;
                    }
                }
            }
        }

        // Collapse short-circuit condition chains that share the same then-block.
        var cond_tree_applied = false;
        if (else_block) |else_id| {
            if (else_id < self.cfg.blocks.len) {
                const else_blk = &self.cfg.blocks[else_id];
                if (else_blk.terminator()) |else_term| {
                    if (ctrl.Analyzer.isConditionalJump(undefined, else_term.opcode)) {
                        if (try self.condChainFalseTarget(else_id, then_block)) |fb| {
                            var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
                            defer in_stack.deinit();
                            var memo: std.AutoHashMapUnmanaged(u32, *Expr) = .{};
                            defer memo.deinit(self.allocator);
                            const cond_expr = (try self.buildCondTree(
                                pattern.condition_block,
                                pattern.condition_block,
                                condition,
                                then_block,
                                fb,
                                base_vals,
                                null,
                                null,
                                &in_stack,
                                &memo,
                            )) orelse null;
                            if (cond_expr) |expr| {
                                condition = expr;
                                else_block = fb;
                                is_elif = false;
                                cond_tree_applied = true;
                            }
                        }
                    }
                }
            }
        }

        var inverted = swapped_true_jump;
        if (cond_tree_applied) {
            if (else_block) |else_id| {
                if (try self.condChainAllTrueJumps(pattern.condition_block, else_id)) {
                    condition = try self.invertConditionExpr(condition);
                    try self.emitDecisionTrace(pattern.condition_block, "if_invert_bool_chain", condition);
                    then_block = else_id;
                    else_block = pattern.then_block;
                    is_elif = false;
                    inverted = true;
                }
            }
        }
        if (!inverted and !cond_tree_applied) {
            if (term) |t| switch (t.opcode) {
                .POP_JUMP_IF_TRUE,
                .POP_JUMP_FORWARD_IF_TRUE,
                .POP_JUMP_BACKWARD_IF_TRUE,
                .JUMP_IF_TRUE,
                => {
                    if (!legacy_cond and !is_elif) {
                        if (else_block) |else_id| {
                            condition = try self.invertConditionExpr(condition);
                            try self.emitDecisionTrace(pattern.condition_block, "if_invert_true_jump", condition);
                            const tmp = then_block;
                            then_block = else_id;
                            else_block = tmp;
                            is_elif = false;
                            inverted = true;
                        }
                    }
                    if (!inverted) {
                        if (else_block) |else_id| {
                            if (self.isTerminalBlock(else_id) and !self.isTerminalBlock(then_block)) {
                                if (try self.condChainAllTrueJumps(pattern.condition_block, else_id)) {
                                    condition = try self.invertConditionExpr(condition);
                                    try self.emitDecisionTrace(pattern.condition_block, "if_invert_terminal_else", condition);
                                    then_block = else_id;
                                    else_block = pattern.then_block;
                                    is_elif = false;
                                    inverted = true;
                                }
                            }
                        }
                    }
                },
                else => {},
            };
        }
        var fallthrough: ?u32 = null;
        if (!is_elif) {
            if (else_block) |else_id| {
                if (self.isTerminalBlock(then_block) and else_id > then_block) {
                    const else_term = self.isTerminalBlock(else_id);
                    if (!else_term or chained_cmp or cond_chain_then) {
                        fallthrough = else_id;
                        else_block = null;
                        self.if_next = else_id;
                    }
                }
            }
        }

        // For JUMP_IF_FALSE/TRUE (Python 3.0), skip the leading POP_TOP in each branch
        // that was used to clean up the condition left on stack
        const skip: usize = if (legacy_cond) 1 else 0;

        var then_vals = base_vals;
        var else_vals = base_vals;
        var then_owned = false;
        var else_owned = false;
        if (term) |t| switch (t.opcode) {
            .JUMP_IF_TRUE_OR_POP => {
                then_vals = try self.cloneStackValuesWithExpr(base_vals, condition);
                then_owned = true;
            },
            .JUMP_IF_FALSE_OR_POP => {
                else_vals = try self.cloneStackValuesWithExpr(base_vals, condition);
                else_owned = true;
            },
            else => {},
        };
        defer if (then_owned) deinitStackValuesSlice(self.allocator, self.allocator, then_vals);
        defer if (else_owned) deinitStackValuesSlice(self.allocator, self.allocator, else_vals);

        // Decompile the then body with inherited stack
        const then_end = blk: {
            if (forced_then_end) |ft| break :blk ft;
            if (fallthrough) |fb| break :blk fb;
            if (else_block) |else_id| {
                if (else_id > then_block) break :blk else_id;
            }
            if (pattern.merge_block) |merge_id| {
                if (merge_id > then_block) break :blk merge_id;
            }
            break :blk try self.branchEnd(then_block, null);
        };
        var then_body = try self.decompileBranchRange(then_block, then_end, then_vals, skip);
        const a = self.arena.allocator();

        // Check for assert pattern: if cond: pass else: raise AssertionError
        if (else_block) |else_id| {
            if (try self.tryDecompileAssert(pattern, condition, else_id, then_body, base_vals, skip)) |assert_stmt| {
                deinitStackValuesSlice(self.allocator, self.allocator, base_vals_buf);
                base_owned = false;
                return assert_stmt;
            }
        }

        // Decompile the else body
        var else_body = if (else_block) |else_id| blk: {
            // Check if else is an elif
            if (is_elif) {
                // Elif needs to start with fresh stack
                deinitStackValuesSlice(self.allocator, self.allocator, base_vals_buf);
                base_owned = false;
                if (else_id <= pattern.condition_block) {
                    break :blk &[_]*Stmt{};
                }

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
                const merge_before_else = if (pattern.merge_block) |merge_id| merge_id < else_id else false;
                const else_end = if (pattern.merge_block) |merge_id|
                    if (merge_before_else)
                        try self.branchEnd(else_id, null)
                    else
                        merge_id
                else
                    try self.branchEnd(else_id, null);
                break :blk try self.decompileBranchRange(else_id, else_end, &.{}, skip);
            }
            // Regular else with inherited stack
            defer {
                deinitStackValuesSlice(self.allocator, self.allocator, base_vals_buf);
                base_owned = false;
            }
            var else_next: ?u32 = null;
            if (else_resolved and else_id < self.cfg.blocks.len) {
                var succ: ?u32 = null;
                var multi = false;
                for (self.cfg.blocks[else_id].successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    if (succ != null) {
                        multi = true;
                        break;
                    }
                    succ = edge.target;
                }
                if (!multi) {
                    else_next = succ;
                    if (self.if_next == null) {
                        if (succ) |sid| {
                            if (!self.isTerminalBlock(sid)) {
                                self.if_next = sid;
                            }
                        }
                    }
                }
            }
            const merge_before_else = if (pattern.merge_block) |merge_id| merge_id < else_id else false;
            const else_end = if (pattern.merge_block) |merge_id|
                if (merge_before_else)
                    try self.branchEnd(else_id, null)
                else if (merge_id == else_id and !else_resolved)
                    try self.branchEnd(else_id, null)
                else if (else_resolved and merge_id == else_id and else_next != null)
                    else_next.?
                else if (else_resolved and merge_id == else_id)
                    try self.branchEnd(else_id, null)
                else
                    merge_id
            else if (else_resolved and else_next != null)
                else_next.?
            else
                try self.branchEnd(else_id, null);
            break :blk try self.decompileBranchRange(else_id, else_end, else_vals, skip);
        } else blk: {
            // No else block - clean up base_vals
            deinitStackValuesSlice(self.allocator, self.allocator, base_vals_buf);
            base_owned = false;
            break :blk &[_]*Stmt{};
        };

        var synth_else = false;
        if (else_block != null) {
            if (else_body.len == 0) {
                if (pattern.merge_block) |merge_id| {
                    if (merge_id < self.cfg.blocks.len and merge_id > pattern.condition_block) {
                        var limit: u32 = @intCast(self.cfg.blocks.len);
                        if (self.br_limit) |lim| {
                            const lim_next = lim + 1;
                            if (lim_next < limit) limit = lim_next;
                        }
                        var reach = try self.reachableInRange(then_block, limit, merge_id);
                        defer reach.deinit();
                        var next_id: ?u32 = null;
                        var bid: u32 = merge_id + 1;
                        while (bid < limit) : (bid += 1) {
                            if (reach.isSet(bid)) {
                                next_id = bid;
                                break;
                            }
                        }
                        if (next_id != null) {
                            var term_id: ?u32 = null;
                            var cur = merge_id;
                            var steps: u32 = 0;
                            var linear = true;
                            while (cur < self.cfg.blocks.len) {
                                steps += 1;
                                if (steps > self.cfg.blocks.len) {
                                    linear = false;
                                    break;
                                }
                                const blk = &self.cfg.blocks[cur];
                                if (blk.terminator()) |t| {
                                    if (ctrl.Analyzer.isConditionalJump(undefined, t.opcode)) {
                                        linear = false;
                                        break;
                                    }
                                }
                                var next: ?u32 = null;
                                var count: u32 = 0;
                                for (blk.successors) |edge| {
                                    if (edge.edge_type == .exception or edge.edge_type == .loop_back) continue;
                                    count += 1;
                                    if (count == 1) next = edge.target;
                                }
                                if (count == 0) {
                                    term_id = cur;
                                    break;
                                }
                                if (count > 1 or next == null) {
                                    linear = false;
                                    break;
                                }
                                cur = next.?;
                            }
                            if (linear and term_id != null) {
                                var tmp: std.ArrayList(*Stmt) = .{};
                                defer tmp.deinit(a);
                                try self.decompileBlockIntoWithStackAndSkip(term_id.?, &tmp, a, &.{}, 0);
                                if (tmp.items.len == 1 and self.stmtIsTerminal(tmp.items[0])) {
                                    const body = try a.alloc(*Stmt, 1);
                                    body[0] = tmp.items[0];
                                    else_body = body;
                                    synth_else = true;

                                    if (self.if_next == null) {
                                        self.if_next = next_id.?;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var appended_term: ?*Stmt = null;
        if (else_block) |else_id| {
            const then_reaches_else = try self.reachesBlock(then_block, else_id, pattern.condition_block);
            var collapsed_else = false;
            const else_preds = if (else_id < self.cfg.blocks.len) self.cfg.blocks[else_id].predecessors.len else 0;
            if (then_reaches_else and else_body.len == 1 and self.stmtIsTerminal(else_body[0]) and self.isTerminalBlock(else_id) and try self.postDominates(else_id, then_block) and else_preds == 1) {
                else_body = &[_]*Stmt{};
                self.if_next = else_id;
                collapsed_else = true;
            }
            if (self.if_next == null and pattern.merge_block == null and !collapsed_else) {
                const else_terminal = self.bodyEndsTerminal(else_body) or self.isTerminalBlock(else_id);
                if (else_terminal) {
                    var limit = then_end;
                    if (then_end <= else_id) {
                        limit = @intCast(self.cfg.blocks.len);
                    }
                    var reach = try self.reachableInRange(then_block, limit, else_id);
                    defer reach.deinit();
                    const else_off = self.cfg.blocks[else_id].start_offset;
                    var fall_candidate: ?u32 = null;
                    var bid: u32 = 0;
                    while (bid < self.cfg.blocks.len) : (bid += 1) {
                        if (!reach.isSet(bid)) continue;
                        if (bid == else_id) continue;
                        const off = self.cfg.blocks[bid].start_offset;
                        if (off <= else_off) continue;
                        if (fall_candidate == null or
                            off < self.cfg.blocks[fall_candidate.?].start_offset)
                        {
                            fall_candidate = bid;
                        }
                    }
                    if (fall_candidate) |next_id| {
                        self.if_next = next_id;
                    }
                }
            }
            if (!collapsed_else and !synth_else and !self.bodyEndsTerminal(then_body)) {
                if (try self.findTerminalStmtFrom(then_block, else_id)) |term_res| {
                    const term_from_else = try self.reachesBlock(else_id, term_res.block_id, pattern.condition_block);
                    if (!term_from_else) {
                        const term_off = self.cfg.blocks[term_res.block_id].start_offset;
                        const else_off = self.cfg.blocks[else_id].start_offset;
                        const same_block = term_res.block_id == else_id;
                        const term_before_else = term_off < else_off or same_block;
                        if (same_block and then_reaches_else and else_body.len == 1 and self.stmtIsTerminal(else_body[0]) and self.terminalStmtEqual(else_body[0], term_res.stmt) and try self.postDominates(else_id, then_block)) {
                            else_body = &[_]*Stmt{};
                            self.if_next = else_id;
                        } else {
                            const else_reaches = if (same_block) false else try self.reachesBlock(else_id, term_res.block_id, null);
                            const term_postdom = try self.postDominates(term_res.block_id, then_block);
                            if (term_before_else and !else_reaches and term_postdom) {
                                then_body = try self.appendStmt(a, then_body, term_res.stmt);
                                appended_term = term_res.stmt;
                            }
                        }
                    }
                }
            }
        }
        if (appended_term) |term_stmt| {
            if (else_body.len == 1 and self.stmtIsTerminal(else_body[0]) and self.terminalStmtEqual(else_body[0], term_stmt)) {
                else_body = &[_]*Stmt{};
            }
        }
        if (merge_else) {
            if (pattern.merge_block) |merge| {
                self.if_next = merge;
            }
            else_body = &[_]*Stmt{};
        }

        if (else_block) |else_id| {
            if (else_id > pattern.condition_block and else_body.len > 0 and try self.reachesBlock(then_block, else_id, pattern.condition_block) and try self.postDominates(else_id, then_block)) {
                else_body = &[_]*Stmt{};
                self.if_next = else_id;
            }
        }

        if (then_body.len == 0 and else_body.len > 0) {
            const else_is_if = else_body.len == 1 and else_body[0].* == .if_stmt;
            const else_is_pass = else_body.len == 1 and else_body[0].* == .pass;
            const can_invert = if (term) |t| switch (t.opcode) {
                .POP_JUMP_IF_TRUE,
                .POP_JUMP_FORWARD_IF_TRUE,
                .POP_JUMP_BACKWARD_IF_TRUE,
                .JUMP_IF_TRUE,
                => true,
                else => false,
            } else false;
            if (can_invert and !else_is_if and !else_is_pass) {
                condition = try self.invertConditionExpr(condition);
                try self.emitDecisionTrace(pattern.condition_block, "if_invert_empty_then", condition);
                then_body = else_body;
                else_body = &[_]*Stmt{};
            }
        }
        if (else_block) |else_id| {
            if (self.if_next == null and else_id > pattern.condition_block and
                condition.* == .unary_op and condition.unary_op.op == .not_ and
                else_body.len == 1 and self.stmtIsTerminal(else_body[0]) and
                self.bodyEndsTerminal(then_body))
            {
                else_body = &[_]*Stmt{};
                self.if_next = else_id;
            }
        }

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

        var reachable = try self.reachableInRange(start_block, limit, end_block);
        defer reachable.deinit();
        var masked: std.ArrayList(u32) = .{};
        defer masked.deinit(self.allocator);
        var bid = start_block;
        while (bid < limit) : (bid += 1) {
            if (!reachable.isSet(bid)) {
                if (!self.consumed.isSet(bid)) {
                    try self.consumed.set(self.allocator, bid);
                    try masked.append(self.allocator, bid);
                }
            }
        }
        defer {
            for (masked.items) |id| {
                self.consumed.unset(id);
            }
        }

        if (skip_first > 0 or base_vals.len > 0) {
            const a = self.arena.allocator();
            var stmts: std.ArrayList(*Stmt) = .{};
            errdefer stmts.deinit(a);

            try self.decompileBlockIntoWithStackAndSkip(start_block, &stmts, a, base_vals, skip_first);

            if (start_block + 1 < limit) {
                const rest = try self.decompileStructuredRange(start_block + 1, limit);
                try stmts.appendSlice(a, rest);
            }

            return stmts.toOwnedSlice(a);
        }

        return self.decompileStructuredRange(start_block, limit);
    }

    /// Decompile a while loop pattern.
    fn decompileWhile(self: *Decompiler, pattern: ctrl.WhilePattern) DecompileError!?*Stmt {
        self.loop_next = null;
        const header = &self.cfg.blocks[pattern.header_block];
        var body_true = true;
        for (header.successors) |edge| {
            if (edge.target == pattern.body_block) {
                if (edge.edge_type == .conditional_false) {
                    body_true = false;
                }
                break;
            }
        }

        // Get the condition expression
        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        var cond_idx: usize = header.instructions.len;
        for (header.instructions, 0..) |inst, idx| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            try sim.simulate(inst);
            cond_idx = idx + 1;
        }

        var condition = try sim.stack.popExpr();

        var body_block_id = pattern.body_block;
        var ignore_header_while = false;
        const exit_is_continue = self.blockLeadsToHeader(pattern.exit_block, pattern.header_block);
        if (exit_is_continue) {
            const a = self.arena.allocator();
            condition = try ast.makeConstant(a, .true_);
            body_block_id = pattern.header_block;
            ignore_header_while = true;
            cond_idx = 0;
        }
        if (body_block_id < self.cfg.blocks.len) {
            const body_pattern = try self.analyzer.detectPattern(body_block_id);
            if (body_pattern == .if_stmt) {
                const guard = body_pattern.if_stmt;
                if (guard.condition_block == body_block_id and guard.else_block != null) {
                    const else_id = guard.else_block.?;
                    const merge_is_then = guard.merge_block != null and
                        (guard.merge_block.? == guard.then_block or guard.merge_block.? == pattern.header_block);
                    const else_is_exit = else_id == pattern.exit_block;
                    const then_in_loop = self.analyzer.inLoop(guard.then_block, pattern.header_block);
                    const can_merge = (merge_is_then or (guard.merge_block == null and else_is_exit)) and then_in_loop;
                    if (can_merge and else_is_exit) {
                        var guard_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
                        defer guard_sim.deinit();
                        const guard_block = &self.cfg.blocks[guard.condition_block];
                        for (guard_block.instructions) |inst| {
                            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                            try guard_sim.simulate(inst);
                        }
                        const guard_cond = try guard_sim.stack.popExpr();
                        const a = self.arena.allocator();
                        const values = try a.alloc(*Expr, 2);
                        values[0] = condition;
                        values[1] = guard_cond;
                        const combined = try a.create(Expr);
                        combined.* = .{ .bool_op = .{ .op = .and_, .values = values } };
                        condition = combined;
                        body_block_id = guard.then_block;
                    }
                }
            }
        }

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer visited.deinit();

        var skip_first = false;
        const term = header.terminator();
        const legacy_cond = if (term) |t| t.opcode == .JUMP_IF_FALSE or t.opcode == .JUMP_IF_TRUE else false;
        const body_block = &self.cfg.blocks[body_block_id];
        var body_skip: usize = 0;
        if (body_block_id == pattern.header_block and !ignore_header_while) {
            for (header.instructions, 0..) |inst, idx| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                    body_skip = idx + 1;
                    break;
                }
            }
        }
        var seed_pop = false;
        if (legacy_cond) {
            if (body_block_id == pattern.header_block) {
                if (body_skip < header.instructions.len and header.instructions[body_skip].opcode == .POP_TOP) {
                    seed_pop = true;
                }
            } else if (body_block.instructions.len > 0 and body_block.instructions[0].opcode == .POP_TOP) {
                seed_pop = true;
            }
        }
        if (ignore_header_while) {
            seed_pop = false;
        }
        const body = try self.decompileLoopBody(
            body_block_id,
            pattern.header_block,
            &skip_first,
            &seed_pop,
            &visited,
            null,
            body_skip,
            ignore_header_while,
        );

        const a = self.arena.allocator();
        var header_stmts: std.ArrayList(*Stmt) = .{};
        errdefer header_stmts.deinit(a);
        var skip_first_store = false;
        if (cond_idx > 0) {
            try self.processPartialBlock(header, &header_stmts, a, &skip_first_store, cond_idx);
        }

        var guard_if: ?*Stmt = null;
        var guard_next: ?u32 = null;
        if (pattern.exit_block < self.cfg.blocks.len) {
            const exit_block = &self.cfg.blocks[pattern.exit_block];
            if (exit_block.predecessors.len == 1 and exit_block.predecessors[0] == pattern.header_block) {
                var has_cond = false;
                for (exit_block.instructions) |inst| {
                    if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                        has_cond = true;
                        break;
                    }
                }
                if (!has_cond) {
                    var succ: ?u32 = null;
                    var multi_succ = false;
                    for (exit_block.successors) |edge| {
                        if (edge.edge_type == .exception) continue;
                        if (succ != null) {
                            multi_succ = true;
                            break;
                        }
                        succ = edge.target;
                    }
                    if (!multi_succ) {
                        const exit_jump = self.jumpTargetIfJumpOnly(pattern.exit_block, true);
                        if (exit_jump == null or (succ != null and exit_jump.? != succ.?)) {
                            const succ_outside = if (succ) |sid| !self.analyzer.inLoop(sid, pattern.header_block) else true;
                            if (succ_outside and (succ == null or self.isTerminalBlock(succ.?))) {
                                var next_block: u32 = pattern.exit_block;
                                const limit: u32 = @intCast(self.cfg.blocks.len);
                                while (next_block < limit) : (next_block += 1) {
                                    if (next_block == pattern.exit_block) continue;
                                    if (self.analyzer.inLoop(next_block, pattern.header_block)) continue;
                                    break;
                                }
                                const exit_stmts = try self.decompileBlockRangeWithStackAndSkip(
                                    pattern.exit_block,
                                    pattern.exit_block + 1,
                                    &.{},
                                    0,
                                );
                                var succ_stmts: []const *Stmt = &.{};
                                var inline_succ = false;
                                if (succ) |sid| {
                                    if (sid != next_block) {
                                        inline_succ = true;
                                    }
                                }
                                if (inline_succ) {
                                    if (succ) |sid| {
                                        succ_stmts = try self.decompileBlockRangeWithStackAndSkip(sid, sid + 1, &.{}, 0);
                                    }
                                }

                                const guard_cond = if (body_true)
                                    try self.invertConditionExpr(condition)
                                else
                                    condition;

                                const guard_len = exit_stmts.len + succ_stmts.len;
                                const needs_break = if (guard_len == 0) true else blk: {
                                    const last = if (succ_stmts.len > 0)
                                        succ_stmts[succ_stmts.len - 1]
                                    else
                                        exit_stmts[exit_stmts.len - 1];
                                    break :blk !self.stmtIsTerminal(last);
                                };
                                const extra = if (needs_break) @as(usize, 1) else 0;
                                const guard_body = try a.alloc(*Stmt, guard_len + extra);
                                if (exit_stmts.len > 0) {
                                    std.mem.copyForwards(*Stmt, guard_body[0..exit_stmts.len], exit_stmts);
                                }
                                if (succ_stmts.len > 0) {
                                    std.mem.copyForwards(
                                        *Stmt,
                                        guard_body[exit_stmts.len .. exit_stmts.len + succ_stmts.len],
                                        succ_stmts,
                                    );
                                }
                                if (needs_break) {
                                    guard_body[guard_len] = try self.makeBreak();
                                }

                                const gs = try a.create(Stmt);
                                gs.* = .{ .if_stmt = .{
                                    .condition = guard_cond,
                                    .body = guard_body,
                                    .else_body = &.{},
                                } };
                                guard_if = gs;
                                try self.consumed.set(self.allocator, pattern.exit_block);
                                if (inline_succ) {
                                    if (succ) |sid| {
                                        try self.consumed.set(self.allocator, sid);
                                    }
                                }
                                guard_next = next_block;
                            }
                        }
                    }
                }
            }
        }

        const trace_on = self.trace_loop_guards and self.trace_file != null;
        var exit_path: std.ArrayListUnmanaged(u32) = .{};
        const exit_to_header = if (pattern.exit_block < self.cfg.blocks.len)
            try self.continuesToHeader(
                pattern.exit_block,
                pattern.header_block,
                if (trace_on) &exit_path else null,
            )
        else
            false;

        var loop_cond = condition;
        if (!body_true) {
            loop_cond = try self.invertConditionExpr(condition);
        }

        var final_condition = loop_cond;
        var final_body = body;
        if (guard_if) |gs| {
            const true_expr = try ast.makeConstant(a, .true_);
            const new_body = try a.alloc(*Stmt, header_stmts.items.len + 1 + body.len);
            if (header_stmts.items.len > 0) {
                std.mem.copyForwards(*Stmt, new_body[0..header_stmts.items.len], header_stmts.items);
            }
            new_body[header_stmts.items.len] = gs;
            if (body.len > 0) {
                std.mem.copyForwards(*Stmt, new_body[header_stmts.items.len + 1 ..], body);
            }
            final_condition = true_expr;
            final_body = new_body;
            if (guard_next) |next| {
                self.loop_next = next;
            }
        } else if (header_stmts.items.len > 0) {
            const true_expr = try ast.makeConstant(a, .true_);
            const guard_cond = if (body_true)
                try self.invertConditionExpr(condition)
            else
                condition;
            const loop_stmt = if (exit_to_header)
                try self.makeContinue()
            else
                try self.makeBreak();
            const break_body = try a.alloc(*Stmt, 1);
            break_body[0] = loop_stmt;
            const guard_stmt = try a.create(Stmt);
            guard_stmt.* = .{ .if_stmt = .{
                .condition = guard_cond,
                .body = break_body,
                .else_body = &.{},
            } };
            if (trace_on) {
                if (term) |t| {
                    try self.emitGuardTrace(
                        pattern.header_block,
                        pattern.header_block,
                        t,
                        pattern.exit_block,
                        guard_cond,
                        header_stmts.items.len,
                        exit_path.items,
                    );
                }
            }

            const new_body = try a.alloc(*Stmt, header_stmts.items.len + 1 + body.len);
            std.mem.copyForwards(*Stmt, new_body[0..header_stmts.items.len], header_stmts.items);
            new_body[header_stmts.items.len] = guard_stmt;
            if (body.len > 0) {
                std.mem.copyForwards(*Stmt, new_body[header_stmts.items.len + 1 ..], body);
            }
            final_condition = true_expr;
            final_body = new_body;
        }

        const stmt = try a.create(Stmt);
        stmt.* = .{
            .while_stmt = .{
                .condition = final_condition,
                .body = final_body,
                .else_body = &.{},
            },
        };

        return stmt;
    }

    fn decompileLoopHeader(self: *Decompiler, header: u32) DecompileError!?PatternResult {
        const body_set = self.analyzer.loopSet(header) orelse return null;
        if (!body_set.isSet(@intCast(header))) return null;

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer visited.deinit();

        var guard_stmt: ?*Stmt = null;
        var header_stmt_count: usize = 0;
        const trace_on = self.trace_loop_guards and self.trace_file != null;
        if (header < self.cfg.blocks.len) {
            const header_block = &self.cfg.blocks[header];
            if (header_block.terminator()) |term| {
                if (ctrl.Analyzer.isConditionalJump(undefined, term.opcode)) {
                    if (try self.guardBranchToHeader(header_block, term, header, trace_on)) |branch| {
                        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
                        defer sim.deinit();
                        sim.lenient = true;
                        sim.stack.allow_underflow = true;
                        if (header < self.stack_in.len) {
                            if (self.stack_in[header]) |entry| {
                                for (entry) |val| {
                                    const cloned = try sim.cloneStackValue(val);
                                    try sim.stack.push(cloned);
                                }
                            }
                        }
                        for (header_block.instructions) |inst| {
                            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                            try sim.simulate(inst);
                        }
                        const cond = try sim.stack.popExpr();
                        const guard_cond = try self.guardCondForBranch(cond, term.opcode, branch.taken);
                        var tmp: std.ArrayList(*Stmt) = .{};
                        defer tmp.deinit(self.arena.allocator());
                        var skip_first_store = false;
                        var term_idx: usize = header_block.instructions.len;
                        for (header_block.instructions, 0..) |inst, idx| {
                            if (inst.offset == term.offset) {
                                term_idx = idx;
                                break;
                            }
                        }
                        if (term_idx > 0) {
                            try self.processPartialBlock(header_block, &tmp, self.arena.allocator(), &skip_first_store, term_idx);
                            header_stmt_count = tmp.items.len;
                        }
                        const a = self.arena.allocator();
                        const cont_stmt = try self.makeContinue();
                        const body = try a.alloc(*Stmt, 1);
                        body[0] = cont_stmt;
                        const if_stmt = try a.create(Stmt);
                        if_stmt.* = .{ .if_stmt = .{
                            .condition = guard_cond,
                            .body = body,
                            .else_body = &.{},
                        } };
                        guard_stmt = if_stmt;
                        if (trace_on) {
                            try self.emitGuardTrace(
                                header,
                                header,
                                term,
                                branch.target,
                                guard_cond,
                                header_stmt_count,
                                branch.path,
                            );
                        }
                    }
                }
            }
        }

        var skip_first = false;
        var seed_pop = false;
        const body = try self.decompileLoopBody(
            header,
            header,
            &skip_first,
            &seed_pop,
            &visited,
            null,
            0,
            false,
        );

        const a = self.arena.allocator();
        const cond = try ast.makeConstant(a, .true_);
        var final_body = body;
        if (guard_stmt) |gs| {
            var wrapped_guard = false;
            if (gs.* == .if_stmt) {
                const guard_if = gs.if_stmt;
                const guard_body = guard_if.body;
                if (guard_if.else_body.len == 0 and guard_body.len == 1 and guard_body[0].* == .continue_stmt) {
                    if (header_stmt_count <= final_body.len) {
                        const rest = final_body[header_stmt_count..];
                        if (rest.len > 0) {
                            const exec_cond = try self.invertConditionExpr(guard_if.condition);
                            const wrap_stmt = try a.create(Stmt);
                            wrap_stmt.* = .{ .if_stmt = .{
                                .condition = exec_cond,
                                .body = rest,
                                .else_body = &.{},
                            } };
                            const new_body = try a.alloc(*Stmt, header_stmt_count + 1);
                            if (header_stmt_count > 0) {
                                std.mem.copyForwards(*Stmt, new_body[0..header_stmt_count], final_body[0..header_stmt_count]);
                            }
                            new_body[header_stmt_count] = wrap_stmt;
                            final_body = new_body;
                            wrapped_guard = true;
                        }
                    }
                }
            }
            if (!wrapped_guard and final_body.len > 0 and final_body[0].* == .try_stmt and header_stmt_count <= final_body[0].try_stmt.body.len) {
                const old = final_body[0].try_stmt.body;
                const guard_dup = if (gs.* == .if_stmt and header_stmt_count < old.len)
                    self.isContGuard(old[header_stmt_count], gs.if_stmt.condition)
                else
                    false;
                if (!guard_dup) {
                    const new_body = try a.alloc(*Stmt, old.len + 1);
                    if (header_stmt_count > 0) {
                        std.mem.copyForwards(*Stmt, new_body[0..header_stmt_count], old[0..header_stmt_count]);
                    }
                    new_body[header_stmt_count] = gs;
                    if (header_stmt_count < old.len) {
                        std.mem.copyForwards(
                            *Stmt,
                            new_body[header_stmt_count + 1 ..],
                            old[header_stmt_count..],
                        );
                    }
                    final_body[0].try_stmt.body = new_body;
                }
            } else if (!wrapped_guard and header_stmt_count <= final_body.len) {
                const guard_dup = if (gs.* == .if_stmt and header_stmt_count < final_body.len)
                    self.isContGuard(final_body[header_stmt_count], gs.if_stmt.condition)
                else
                    false;
                if (!guard_dup) {
                    const new_body = try a.alloc(*Stmt, final_body.len + 1);
                    if (header_stmt_count > 0) {
                        std.mem.copyForwards(*Stmt, new_body[0..header_stmt_count], final_body[0..header_stmt_count]);
                    }
                    new_body[header_stmt_count] = gs;
                    if (header_stmt_count < final_body.len) {
                        std.mem.copyForwards(
                            *Stmt,
                            new_body[header_stmt_count + 1 ..],
                            final_body[header_stmt_count..],
                        );
                    }
                    final_body = new_body;
                }
            }
        }
        const stmt = try a.create(Stmt);
        stmt.* = .{
            .while_stmt = .{
                .condition = cond,
                .body = final_body,
                .else_body = &.{},
            },
        };

        var exit_block: ?u32 = null;
        var max_block: u32 = header;
        var it = body_set.iterator(.{});
        while (it.next()) |bit| {
            const bid: u32 = @intCast(bit);
            if (bid > max_block) max_block = bid;
            const blk = &self.cfg.blocks[bid];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (!body_set.isSet(@intCast(edge.target))) {
                    exit_block = if (exit_block) |prev|
                        @min(prev, edge.target)
                    else
                        edge.target;
                }
            }
        }

        const limit: u32 = @intCast(self.cfg.blocks.len);
        const next_block = exit_block orelse blk: {
            const candidate = max_block + 1;
            break :blk if (candidate < limit) candidate else limit;
        };

        return .{ .stmt = stmt, .next_block = next_block };
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

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        for (aiter_block.instructions) |inst| {
            if (inst.opcode == .GET_AITER) break;
            try sim.simulate(inst);
        }
        const iter_expr = try sim.stack.popExpr();

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
                        elts[j] = try self.makeName(name, .store);
                    }
                    target = try a.create(Expr);
                    target.* = .{ .tuple = .{ .elts = elts, .ctx = .store } };
                    found_target = true;
                    break;
                },
                .STORE_FAST => {
                    const name = sim.getLocal(inst.arg) orelse "_";
                    target = try self.makeName(name, .store);
                    found_target = true;
                    break;
                },
                .STORE_DEREF => {
                    const name = sim.getDeref(inst.arg) orelse "_";
                    target = try self.makeName(name, .store);
                    found_target = true;
                    break;
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    const name = sim.getName(inst.arg) orelse "_";
                    target = try self.makeName(name, .store);
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
            // Initialize stack with 3 placeholder exprs for exception handler context
            const exc_stack = &[_]StackValue{
                .{ .expr = blk: {
                    const e = try a.create(Expr);
                    e.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                    break :blk e;
                } },
                .{ .expr = blk: {
                    const e = try a.create(Expr);
                    e.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                    break :blk e;
                } },
                .{ .expr = blk: {
                    const e = try a.create(Expr);
                    e.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                    break :blk e;
                } },
            };
            body = try self.decompileStructuredRangeWithStack(body_block, exit_block, exc_stack);
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
        return self.decompileTryWithLoop(pattern, null, null);
    }

    fn decompileTryWithLoop(
        self: *Decompiler,
        pattern: ctrl.TryPattern,
        loop_header: ?u32,
        visited: ?*std.DynamicBitSet,
    ) DecompileError!PatternResult {
        if (pattern.handlers_owned) {
            defer self.allocator.free(pattern.handlers);
        }

        var handler_blocks: std.ArrayListUnmanaged(u32) = .{};
        defer handler_blocks.deinit(self.allocator);
        if (pattern.handlers.len > 0) {
            try handler_blocks.ensureTotalCapacity(self.allocator, pattern.handlers.len);
        }

        for (pattern.handlers) |handler| {
            if (handler.handler_block >= self.cfg.blocks.len) continue;
            try handler_blocks.append(self.allocator, handler.handler_block);
        }
        if (handler_blocks.items.len == 0) {
            return .{ .stmt = null, .next_block = pattern.try_block + 1 };
        }

        std.mem.sort(u32, handler_blocks.items, {}, std.sort.asc(u32));
        const handler_start = handler_blocks.items[0];

        if (self.version.gte(3, 11)) {
            return try self.decompileTry311(pattern, handler_blocks.items);
        }

        const scratch = try self.getTryScratch(self.cfg.blocks.len);
        var handler_set = &scratch.handler_set;
        handler_set.reset();
        for (handler_blocks.items) |hid| {
            try handler_set.set(self.allocator, hid);
        }

        var protected_set = &scratch.protected_set;
        protected_set.reset();
        for (handler_blocks.items) |hid| {
            if (hid >= self.cfg.blocks.len) continue;
            const handler = &self.cfg.blocks[hid];
            for (handler.predecessors) |pred_id| {
                if (pred_id >= self.cfg.blocks.len) continue;
                const pred = &self.cfg.blocks[pred_id];
                for (pred.successors) |edge| {
                    if (edge.edge_type == .exception and edge.target == hid) {
                        try protected_set.set(self.allocator, pred_id);
                        break;
                    }
                }
            }
        }
        if (visited) |v| {
            for (protected_set.list.items) |bid| {
                if (bid < self.cfg.blocks.len) {
                    v.set(bid);
                }
            }
        }

        var post_try_entry: ?u32 = null;
        for (protected_set.list.items) |bid| {
            const block = &self.cfg.blocks[bid];
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (protected_set.isSet(edge.target)) continue;
                if (handler_set.isSet(edge.target)) continue;
                var candidate = edge.target;
                if (candidate < handler_start) {
                    const resolved = self.resolveJumpOnlyBlock(candidate);
                    if (resolved <= handler_start) continue;
                    candidate = resolved;
                    if (candidate >= self.cfg.blocks.len) continue;
                    if (protected_set.isSet(candidate)) continue;
                    if (handler_set.isSet(candidate)) continue;
                }
                post_try_entry = if (post_try_entry) |prev|
                    @min(prev, candidate)
                else
                    candidate;
            }
        }

        var handler_reach = &scratch.handler_reach;
        const allow_loop_back = loop_header == null;
        try self.collectReachableNoExceptionFromStarts(
            handler_blocks.items,
            handler_set,
            handler_reach,
            &scratch.queue,
            allow_loop_back,
        );

        var join_block: ?u32 = null;
        if (post_try_entry) |entry| {
            try self.collectReachableNoExceptionInto(
                entry,
                handler_set,
                &scratch.normal_reach,
                &scratch.queue,
                false,
                allow_loop_back,
            );
            for (scratch.normal_reach.list.items) |bid| {
                if (handler_reach.isSet(bid)) {
                    join_block = bid;
                    break;
                }
            }
        }

        var pattern_exit = pattern.exit_block;
        if (pattern_exit) |exit| {
            if (handler_reach.isSet(exit)) {
                var in_normal = false;
                if (post_try_entry != null) {
                    in_normal = scratch.normal_reach.isSet(exit);
                }
                if (!in_normal) {
                    pattern_exit = null;
                }
            }
        }

        const effective_exit: ?u32 = if (pattern_exit) |exit|
            self.resolveJumpOnlyBlock(exit)
        else if (join_block) |join|
            self.resolveJumpOnlyBlock(join)
        else if (post_try_entry) |entry|
            self.resolveJumpOnlyBlock(entry)
        else
            null;
        var exit_block = effective_exit;
        if (exit_block) |exit| {
            if (exit <= handler_start) {
                exit_block = null;
            }
        }

        var has_finally = false;
        for (handler_blocks.items) |hid| {
            if (self.isFinallyHandler(hid)) {
                has_finally = true;
                break;
            }
        }

        var effective_finally_block = if (has_finally) pattern.finally_block else null;
        if (effective_finally_block != null) {
            var try_entry: ?u32 = null;
            const try_blk = &self.cfg.blocks[pattern.try_block];
            for (try_blk.successors) |edge| {
                if (edge.edge_type == .normal) {
                    try_entry = edge.target;
                    break;
                }
            }
            if (effective_finally_block.? == pattern.try_block or (try_entry != null and effective_finally_block.? == try_entry.?)) {
                var cleanup_candidate: ?u32 = null;
                for (self.cfg.blocks) |*blk| {
                    if (blk.instructions.len != 1) continue;
                    if (blk.instructions[0].opcode != .POP_BLOCK) continue;
                    var has_exc = false;
                    var normal_target: ?u32 = null;
                    var multi = false;
                    for (blk.successors) |edge| {
                        if (edge.edge_type == .exception) {
                            for (handler_blocks.items) |hid| {
                                if (edge.target == hid) {
                                    has_exc = true;
                                    break;
                                }
                            }
                        } else if (edge.edge_type == .normal) {
                            if (normal_target != null) {
                                multi = true;
                                break;
                            }
                            normal_target = edge.target;
                        }
                    }
                    if (multi or !has_exc or normal_target == null) continue;
                    var is_handler = false;
                    for (handler_blocks.items) |hid| {
                        if (normal_target.? == hid) {
                            is_handler = true;
                            break;
                        }
                    }
                    if (is_handler) continue;
                    if (cleanup_candidate == null or
                        self.cfg.blocks[normal_target.?].start_offset <
                            self.cfg.blocks[cleanup_candidate.?].start_offset)
                    {
                        cleanup_candidate = normal_target.?;
                    }
                }
                if (cleanup_candidate) |cand| {
                    effective_finally_block = cand;
                }
            }
        }

        var except_count: usize = 0;
        for (handler_blocks.items) |hid| {
            if (!self.isFinallyHandler(hid)) except_count += 1;
        }

        var else_start: ?u32 = pattern.else_block orelse blk: {
            if (post_try_entry) |entry| {
                if (!handler_reach.isSet(entry)) {
                    if (join_block == null or entry != join_block.?) {
                        break :blk entry;
                    }
                }
            }
            break :blk null;
        };

        if (has_finally and except_count == 0) {
            else_start = null;
        }
        if (loop_header) |header_id| {
            if (else_start) |start| {
                const resolved = self.resolveJumpOnlyBlock(start);
                if (!self.analyzer.inLoop(resolved, header_id) or resolved == header_id or
                    self.loopBlockLeadsToContinue(start, header_id))
                {
                    else_start = null;
                }
            }
        }

        const exit_for_range: ?u32 = if (exit_block) |exit|
            if (else_start) |start|
                (if (exit == start) null else exit)
            else
                exit
        else
            null;

        const finally_start: ?u32 = effective_finally_block orelse blk: {
            if (has_finally) {
                break :blk join_block orelse post_try_entry;
            }
            break :blk null;
        };

        var try_end: u32 = handler_start;
        if (else_start) |start| {
            if (start < try_end) try_end = start;
        }
        if (finally_start) |start| {
            if (start < try_end) try_end = start;
        }

        const try_body = if (pattern.try_block < try_end)
            try self.decompileTryBody(pattern.try_block, try_end, loop_header, visited)
        else
            &[_]*Stmt{};

        const a = self.arena.allocator();

        var loop_exit: ?u32 = null;
        if (loop_header) |header_id| {
            if (header_id < self.cfg.blocks.len) {
                const header_blk = &self.cfg.blocks[header_id];
                for (header_blk.successors) |edge| {
                    if (edge.edge_type == .conditional_false) {
                        loop_exit = edge.target;
                        break;
                    }
                }
            }
        }

        var else_end: u32 = @as(u32, @intCast(self.cfg.blocks.len));
        if (exit_for_range) |exit| {
            if (else_start) |start| {
                if (exit > start) else_end = exit;
            } else {
                else_end = exit;
            }
        }
        if (loop_exit) |exit| {
            if (else_start) |start| {
                if (exit > start and exit < else_end) else_end = exit;
            }
        }
        if (else_start) |start| {
            if (handler_start > start and handler_start < else_end) else_end = handler_start;
            if (finally_start) |final_start| {
                if (final_start > start and final_start < else_end) else_end = final_start;
            }
            if (join_block) |join| {
                if (join > start and join < else_end) else_end = join;
            }
        }

        var else_body = if (else_start) |start| blk: {
            if (start >= else_end) break :blk &[_]*Stmt{};
            if (loop_header != null) {
                break :blk try self.decompileBranchRange(start, else_end, &.{}, 0);
            }
            break :blk try self.decompileStructuredRange(start, else_end);
        } else &[_]*Stmt{};
        if (else_body.len == 1 and Decompiler.isReturnNone(else_body[0])) {
            else_body = &[_]*Stmt{};
        }

        if (loop_header) |header_id| {
            if (else_start) |start| {
                var needs_break = false;
                var bid = start;
                while (bid < else_end and bid < self.cfg.blocks.len) : (bid += 1) {
                    const exit = self.analyzer.detectLoopExit(bid, &[_]u32{header_id});
                    if (exit == .break_stmt or self.loopBlockLeadsToBreak(bid, header_id)) {
                        needs_break = true;
                        break;
                    }
                }
                if (needs_break) {
                    if (else_body.len == 0) {
                        const br = try self.makeBreak();
                        const body = try self.arena.allocator().alloc(*Stmt, 1);
                        body[0] = br;
                        else_body = body;
                    } else {
                        const last = else_body[else_body.len - 1];
                        const terminal = switch (last.*) {
                            .break_stmt, .return_stmt, .raise_stmt, .continue_stmt => true,
                            else => false,
                        };
                        if (!terminal) {
                            const br = try self.makeBreak();
                            const body = try self.arena.allocator().alloc(*Stmt, else_body.len + 1);
                            std.mem.copyForwards(*Stmt, body[0..else_body.len], else_body);
                            body[else_body.len] = br;
                            else_body = body;
                        }
                    }
                }
            }
        }

        var final_end: u32 = @as(u32, @intCast(self.cfg.blocks.len));
        if (exit_for_range) |exit| {
            if (finally_start) |start| {
                if (exit > start) final_end = exit;
            } else {
                final_end = exit;
            }
        }
        if (finally_start) |final_start| {
            if (handler_start > final_start and handler_start < final_end) {
                final_end = handler_start;
            }
        }

        const final_body = if (finally_start) |start| blk: {
            if (start >= final_end) break :blk &[_]*Stmt{};
            var exc_stack: [3]StackValue = undefined;
            for (&exc_stack) |*slot| {
                const placeholder = try a.create(Expr);
                placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                slot.* = .{ .expr = placeholder };
            }
            break :blk try self.decompileStructuredRangeWithStack(start, final_end, &exc_stack);
        } else &[_]*Stmt{};

        var next_block: u32 = final_end;
        if (next_block < try_end) next_block = try_end;
        if (else_start) |start| {
            if (start > next_block) next_block = start;
        }
        if (exit_for_range) |exit| {
            if (exit > next_block) next_block = exit;
        }
        const last_handler = handler_blocks.items[handler_blocks.items.len - 1];
        if (next_block <= last_handler) {
            next_block = last_handler + 1;
        }
        const loop_has_tail = if (loop_header) |header_id|
            next_block < self.cfg.blocks.len and next_block != header_id and self.analyzer.inLoop(next_block, header_id)
        else
            false;

        var handler_nodes = try a.alloc(ast.ExceptHandler, except_count);
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

        var seen_bare = false;
        for (handler_blocks.items, 0..) |hid, idx| {
            if (self.isFinallyHandler(hid)) continue;
            const handler_end = blk: {
                const next_handler = if (idx + 1 < handler_blocks.items.len)
                    handler_blocks.items[idx + 1]
                else
                    (exit_block orelse @as(u32, @intCast(self.cfg.blocks.len)));
                if (finally_start) |start| {
                    if (start > hid and start < next_handler) break :blk start;
                }
                break :blk next_handler;
            };

            const info = try self.extractHandlerHeader(hid);
            var body_end = handler_end;
            var scan_block = info.body_block;
            while (scan_block < body_end and scan_block < self.cfg.blocks.len) {
                const scan_blk = &self.cfg.blocks[scan_block];
                var found_pop_except = false;
                for (scan_blk.instructions) |inst| {
                    if (inst.opcode == .POP_EXCEPT) {
                        found_pop_except = true;
                        break;
                    }
                }
                if (found_pop_except) {
                    body_end = scan_block + 1;
                    break;
                }
                scan_block += 1;
            }
            var body = try self.decompileHandlerBody(info.body_block, body_end, info.skip_first_store, info.skip);
            if (body.len == 0 and (info.skip_first_store or info.skip > 0)) {
                body = try self.decompileHandlerBody(info.body_block, body_end, false, 0);
            }
            if (body.len == 0) {
                body = try self.decompileHandlerBodyLinear(info.body_block, body_end, info.skip);
            }
            if (info.name) |handler_name| {
                if (body.len > 0) {
                    const first = body[0];
                    if (first.* == .assign and first.assign.targets.len == 1) {
                        const target = first.assign.targets[0];
                        if (target.* == .name and std.mem.eql(u8, target.name.id, handler_name) and
                            self.isPlaceholderExpr(first.assign.value))
                        {
                            body = body[1..];
                        }
                    }
                }
            }
            if (body.len == 1 and body[0].* == .try_stmt) {
                const inner = body[0].try_stmt;
                const final_is_empty = inner.finalbody.len == 0 or (inner.finalbody.len == 1 and inner.finalbody[0].* == .pass);
                if (inner.handlers.len == 0 and inner.else_body.len == 0 and final_is_empty) {
                    body = inner.body;
                }
            }
            if (loop_header) |header_id| {
                if (loop_has_tail and body.len == 0 and self.handlerIsContinue(info.body_block, body_end, header_id)) {
                    const cont = try self.makeContinue();
                    const body_one = try a.alloc(*Stmt, 1);
                    body_one[0] = cont;
                    body = body_one;
                }
            }
            const is_bare = info.exc_type == null;
            if (is_bare and seen_bare and isEmptyHandlerBody(body)) {
                continue;
            }
            if (is_bare) seen_bare = true;

            var handler_name = info.name;
            if (handler_name == null and body.len > 0) {
                const first = body[0];
                if (first.* == .assign and first.assign.targets.len == 1) {
                    const target = first.assign.targets[0];
                    if (target.* == .name and self.isPlaceholderExpr(first.assign.value)) {
                        handler_name = target.name.id;
                        body = body[1..];
                    }
                }
            }

            handler_nodes[handler_count] = .{
                .type = info.exc_type,
                .name = handler_name,
                .body = body,
            };
            handler_count += 1;
        }

        for (handler_reach.list.items) |hid| {
            if (effective_exit) |exit_id| {
                if (hid == exit_id) continue;
            }
            if (post_try_entry) |entry_id| {
                if (hid == entry_id) continue;
                if (scratch.normal_reach.isSet(hid)) continue;
            }
            if (join_block) |join_id| {
                if (hid == join_id) continue;
            }
            if (loop_header) |header_id| {
                if (hid >= next_block and self.analyzer.inLoop(hid, header_id)) continue;
            }
            if (!self.consumed.isSet(hid)) {
                try self.consumed.set(self.allocator, hid);
            }
        }

        const handlers_slice = handler_nodes[0..handler_count];
        const stmt = try a.create(Stmt);
        stmt.* = .{
            .try_stmt = .{
                .body = try_body,
                .handlers = handlers_slice,
                .else_body = else_body,
                .finalbody = final_body,
            },
        };

        return .{ .stmt = stmt, .next_block = next_block };
    }

    fn findWithNormalExit(self: *Decompiler, body_block: u32, cleanup_block: u32) ?u32 {
        var cur = body_block;
        var steps: usize = 0;
        while (cur < self.cfg.blocks.len and steps < 32) : (steps += 1) {
            const blk = &self.cfg.blocks[cur];
            if (!blk.is_exception_handler) {
                var has_pop = false;
                for (blk.instructions) |inst| {
                    if (inst.opcode == .POP_BLOCK) {
                        has_pop = true;
                        break;
                    }
                }
                if (has_pop) {
                    var next: ?u32 = null;
                    for (blk.successors) |edge| {
                        if (edge.edge_type == .normal) {
                            next = edge.target;
                            break;
                        }
                    }
                    if (next) |nb| {
                        const next_blk = &self.cfg.blocks[nb];
                        var after: ?u32 = null;
                        for (next_blk.successors) |edge| {
                            if (edge.edge_type == .normal) {
                                after = edge.target;
                                break;
                            }
                        }
                        return after orelse nb;
                    }
                    return null;
                }
            }
            var next_norm: ?u32 = null;
            for (blk.successors) |edge| {
                if (edge.edge_type == .normal) {
                    next_norm = edge.target;
                    break;
                }
            }
            if (next_norm) |next_id| {
                if (next_id == cleanup_block) break;
                cur = next_id;
                continue;
            }
            break;
        }
        return null;
    }

    fn decompileWith(self: *Decompiler, pattern: ctrl.WithPattern) DecompileError!PatternResult {
        const a = self.arena.allocator();
        const setup = &self.cfg.blocks[pattern.setup_block];
        var sim = self.initSim(a, a, self.code, self.version);
        defer sim.deinit();

        var is_async = false;
        var optional_vars: ?*Expr = null;
        var context_expr: ?*Expr = null;

        // Python 3.14+ uses LOAD_SPECIAL; legacy uses SETUP_WITH
        // Capture the context expression before COPY/LOAD_SPECIAL/SETUP_WITH
        for (setup.instructions) |inst| {
            switch (inst.opcode) {
                .BEFORE_ASYNC_WITH => is_async = true,
                .SETUP_ASYNC_WITH => is_async = true,
                else => {},
            }

            // Capture context expression right before COPY/LOAD_SPECIAL/SETUP_WITH (clone, don't pop)
            if ((inst.opcode == .COPY or inst.opcode == .LOAD_SPECIAL or inst.opcode == .SETUP_WITH or inst.opcode == .SETUP_ASYNC_WITH) and context_expr == null) {
                if (sim.stack.peekExpr()) |top_expr| {
                    context_expr = try ast.cloneExpr(a, top_expr);
                }
            }

            // Stop at LOAD_SPECIAL/SETUP_WITH - rest is just method binding or with body
            if (inst.opcode == .LOAD_SPECIAL or inst.opcode == .SETUP_WITH or inst.opcode == .SETUP_ASYNC_WITH or inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH) {
                break;
            }

            try sim.simulate(inst);
        }

        if (context_expr == null) {
            context_expr = try self.tryExtractWithContextFromPred(pattern.setup_block);
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
                            optional_vars = try self.makeName(name, .store);
                        }
                    },
                    .STORE_NAME, .STORE_GLOBAL => {
                        if (sim.getName(first.arg)) |name| {
                            optional_vars = try self.makeName(name, .store);
                        }
                    },
                    else => {},
                }
            }
        }

        const ctx_expr = context_expr orelse try sim.stack.popExpr();

        const item = try a.alloc(ast.WithItem, 1);
        item[0] = .{
            .context_expr = ctx_expr,
            .optional_vars = optional_vars,
        };

        var body_end: u32 = pattern.body_block + 1;

        // Decompile body without try-pattern detection; with cleanup adds exception edges.
        var body: []const *Stmt = &.{};
        if (pattern.body_block < self.cfg.blocks.len) {
            var init_stack: []const StackValue = &.{};
            if (pattern.body_block < self.stack_in.len) {
                if (self.stack_in[pattern.body_block]) |entry| {
                    init_stack = entry;
                }
            }
            if (init_stack.len == 0) {
                const exit_expr = try self.makeName("__with_exit__", .load);
                const seed = try a.alloc(StackValue, 2);
                seed[0] = .{ .expr = exit_expr };
                seed[1] = .unknown;
                init_stack = seed;
            }

            body_end = pattern.cleanup_block;
            if (body_end <= pattern.body_block) body_end = pattern.exit_block;
            if (body_end <= pattern.body_block) body_end = pattern.body_block + 1;

            var body_slice = try self.decompileStructuredRangeNoTryWithStack(pattern.body_block, body_end, init_stack);
            if (optional_vars) |opt| {
                if (body_slice.len > 0 and body_slice[0].* == .assign) {
                    const assign = body_slice[0].assign;
                    if (assign.targets.len == 1 and ast.exprEqual(assign.targets[0], opt)) {
                        body_slice = body_slice[1..];
                    }
                }
            }
            body = body_slice;
        }

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

        if (self.findWithNormalExit(pattern.body_block, pattern.cleanup_block)) |normal_exit| {
            if (normal_exit >= body_end) {
                exit = normal_exit;
            }
        }

        return .{ .stmt = stmt, .next_block = exit };
    }

    fn tryExtractWithContextFromPred(self: *Decompiler, setup_block: u32) DecompileError!?*Expr {
        const a = self.arena.allocator();
        if (setup_block >= self.cfg.blocks.len) return null;
        const setup = &self.cfg.blocks[setup_block];

        for (setup.predecessors) |pred_id| {
            const pred = &self.cfg.blocks[pred_id];
            var has_normal = false;
            for (pred.successors) |edge| {
                if (edge.edge_type == .normal and edge.target == setup_block) {
                    has_normal = true;
                    break;
                }
            }
            if (!has_normal) continue;

            var pred_sim = self.initSim(a, a, self.code, self.version);
            defer pred_sim.deinit();
            pred_sim.lenient = true;
            pred_sim.stack.allow_underflow = true;

            var ok = true;
            for (pred.instructions) |inst| {
                if (inst.opcode == .NOT_TAKEN) continue;
                // If the block ends in a jump, don't simulate past it.
                if (inst.isUnconditionalJump()) {
                    break;
                }
                pred_sim.simulate(inst) catch {
                    ok = false;
                    break;
                };
                if (inst.isConditionalJump()) break;
            }

            if (!ok) continue;
            if (pred_sim.stack.len() == 0) continue;
            const top = pred_sim.stack.items.items[pred_sim.stack.items.items.len - 1];
            if (top == .expr) {
                return try ast.cloneExpr(a, top.expr);
            }
        }

        return null;
    }

    fn decompileMatch(self: *Decompiler, pattern: ctrl.MatchPattern) DecompileError!PatternResult {
        defer pattern.deinit(self.allocator);
        // Get subject from subject block - simulate only until MATCH_* or COPY
        const subj_block = &self.cfg.blocks[pattern.subject_block];
        const a = self.arena.allocator();
        var sim = self.initSim(a, a, self.code, self.version);
        defer sim.deinit();
        var prev_was_load = false;
        for (subj_block.instructions) |inst| {
            // Stop before MATCH_* opcodes or COPY
            if (inst.opcode == .MATCH_SEQUENCE or inst.opcode == .MATCH_MAPPING or
                inst.opcode == .MATCH_CLASS or inst.opcode == .COPY)
            {
                break;
            }
            // Stop before STORE if previous was LOAD (pattern binding, not assignment)
            if ((inst.opcode == .STORE_NAME or inst.opcode == .STORE_FAST) and prev_was_load) {
                break;
            }
            // Stop before STORE_FAST_LOAD_FAST (pattern binding in Python 3.14+)
            if (inst.opcode == .STORE_FAST_LOAD_FAST) {
                break;
            }
            prev_was_load = inst.opcode == .LOAD_NAME or inst.opcode == .LOAD_FAST;
            try sim.simulate(inst);
        }

        const subject = try sim.stack.popExpr();

        // Decompile each case
        var cases: std.ArrayList(ast.MatchCase) = .{};
        errdefer cases.deinit(a);
        var extra_blocks: std.ArrayList(u32) = .{};
        defer extra_blocks.deinit(self.allocator);

        var idx: usize = 0;
        while (idx < pattern.case_blocks.len) {
            const case_block_id = pattern.case_blocks[idx];
            if (try self.tryMatchOrChain(pattern.case_blocks, idx)) |chain| {
                const res = try self.decompileMatchCase(chain.guard_block, false);
                var case = res.case;
                const or_pat = try a.create(ast.Pattern);
                or_pat.* = .{ .match_or = chain.patterns };
                case.pattern = or_pat;
                try cases.append(a, case);
                const tail_res = try self.decompileMatchCase(chain.last_block, false);
                try extra_blocks.append(self.allocator, chain.guard_block);
                if (res.fallback_block) |fb| {
                    try extra_blocks.append(self.allocator, fb);
                }
                var fb_body_opt = res.fallback_body;
                var fb_block_opt = res.fallback_block;
                if (fb_body_opt == null) {
                    fb_body_opt = tail_res.fallback_body;
                    fb_block_opt = tail_res.fallback_block;
                }
                if (fb_body_opt == null) {
                    if (chain.fail_block) |fb| {
                        var resolved = fb;
                        if (self.jumpTargetIfJumpOnly(fb, true)) |target| {
                            resolved = target;
                        }
                        if (indexOfBlock(pattern.case_blocks, resolved) == null) {
                            var fb_end: u32 = resolved + 1;
                            const fblk = &self.cfg.blocks[resolved];
                            if (fblk.successors.len > 0) {
                                fb_end = fblk.successors[0].target;
                            }
                            if (resolved < fb_end) {
                                const pop_need = self.maxLeadPop(resolved, fb_end);
                                if (pop_need > 0) {
                                    if (pop_need == 1) {
                                        var init_stack = [_]StackValue{.unknown};
                                        fb_body_opt = try self.decompileStructuredRangeWithStack(resolved, fb_end, init_stack[0..]);
                                    } else {
                                        const init_stack = try self.allocator.alloc(StackValue, pop_need);
                                        defer self.allocator.free(init_stack);
                                        for (init_stack) |*sv| sv.* = .unknown;
                                        fb_body_opt = try self.decompileStructuredRangeWithStack(resolved, fb_end, init_stack);
                                    }
                                } else {
                                    fb_body_opt = try self.decompileStructuredRange(resolved, fb_end);
                                }
                                fb_block_opt = resolved;
                            }
                        }
                    }
                }
                if (fb_body_opt) |fb_body| {
                    if (fb_block_opt != null and pattern.exit_block != null and
                        fb_block_opt.? == pattern.exit_block.? and
                        fb_body.len == 1 and Decompiler.isReturnNone(fb_body[0]))
                    {
                        idx = chain.next_idx;
                        continue;
                    }
                    if (fb_block_opt) |fb| {
                        const is_case = indexOfBlock(pattern.case_blocks, fb) != null and fb != chain.last_block;
                        if (!is_case) {
                            const p = try a.create(ast.Pattern);
                            p.* = .{ .match_as = .{ .pattern = null, .name = null } };
                            try cases.append(a, .{
                                .pattern = p,
                                .guard = null,
                                .body = fb_body,
                            });
                        }
                    } else {
                        var has_wc = false;
                        for (cases.items) |c| {
                            if (isWildcardPattern(c.pattern)) {
                                has_wc = true;
                                break;
                            }
                        }
                        if (!has_wc) {
                            const p = try a.create(ast.Pattern);
                            p.* = .{ .match_as = .{ .pattern = null, .name = null } };
                            try cases.append(a, .{
                                .pattern = p,
                                .guard = null,
                                .body = fb_body,
                            });
                        }
                    }
                }
                idx = chain.next_idx;
                continue;
            }

            // First case has COPY, subsequent cases reuse subject on stack
            const has_copy = idx == 0;
            const res = try self.decompileMatchCase(case_block_id, has_copy);
            try cases.append(a, res.case);
            if (res.fallback_block) |fb| {
                try extra_blocks.append(self.allocator, fb);
            }
            if (res.fallback_body) |fb_body| {
                if (res.fallback_block != null and pattern.exit_block != null and
                    res.fallback_block.? == pattern.exit_block.? and
                    fb_body.len == 1 and Decompiler.isReturnNone(fb_body[0]))
                {
                    idx += 1;
                    continue;
                }
                if (res.fallback_block) |fb| {
                    if (indexOfBlock(pattern.case_blocks, fb) == null) {
                        const p = try a.create(ast.Pattern);
                        p.* = .{ .match_as = .{ .pattern = null, .name = null } };
                        try cases.append(a, .{
                            .pattern = p,
                            .guard = null,
                            .body = fb_body,
                        });
                    }
                } else {
                    var has_wc = false;
                    for (cases.items) |c| {
                        if (isWildcardPattern(c.pattern)) {
                            has_wc = true;
                            break;
                        }
                    }
                    if (!has_wc) {
                        const p = try a.create(ast.Pattern);
                        p.* = .{ .match_as = .{ .pattern = null, .name = null } };
                        try cases.append(a, .{
                            .pattern = p,
                            .guard = null,
                            .body = fb_body,
                        });
                    }
                }
            }
            idx += 1;
        }

        const stmt = try a.create(Stmt);
        stmt.* = .{
            .match_stmt = .{
                .subject = subject,
                .cases = try cases.toOwnedSlice(self.arena.allocator()),
            },
        };

        // Find the highest block ID used - must account for all blocks touched:
        // - pattern blocks (multi-block patterns)
        // - body blocks
        // - fail blocks (conditional_false targets)
        // Use exit_block if available, otherwise find max from all successors
        if (pattern.exit_block) |exit| {
            return .{ .stmt = stmt, .next_block = exit };
        }

        // No explicit exit - find max block by examining all case block successors
        var max_block = pattern.subject_block;
        for (pattern.case_blocks) |cb| {
            if (cb > max_block) max_block = cb;
            const blk = &self.cfg.blocks[cb];
            for (blk.successors) |edge| {
                if (edge.target > max_block) max_block = edge.target;
            }
        }
        for (extra_blocks.items) |cb| {
            if (cb > max_block) max_block = cb;
            const blk = &self.cfg.blocks[cb];
            for (blk.successors) |edge| {
                if (edge.target > max_block) max_block = edge.target;
            }
        }
        return .{ .stmt = stmt, .next_block = max_block + 1 };
    }

    fn matchPreludeEnd(self: *Decompiler, block: *const cfg_mod.BasicBlock) usize {
        _ = self;
        var prev_was_load = false;
        for (block.instructions, 0..) |inst, i| {
            if (inst.opcode == .MATCH_SEQUENCE or inst.opcode == .MATCH_MAPPING or
                inst.opcode == .MATCH_CLASS or inst.opcode == .MATCH_KEYS or inst.opcode == .COPY)
            {
                return i;
            }
            if ((inst.opcode == .STORE_NAME or inst.opcode == .STORE_FAST) and prev_was_load) {
                return i;
            }
            if (inst.opcode == .STORE_FAST_LOAD_FAST) {
                return i;
            }
            prev_was_load = inst.opcode == .LOAD_NAME or inst.opcode == .LOAD_FAST or
                inst.opcode == .LOAD_GLOBAL or inst.opcode == .LOAD_DEREF or
                inst.opcode == .LOAD_FAST_BORROW;
        }
        return block.instructions.len;
    }

    fn emitMatchPrelude(
        self: *Decompiler,
        block_id: u32,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
    ) DecompileError!void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];
        var first_idx: ?usize = null;
        for (block.instructions, 0..) |inst, i| {
            if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
            first_idx = i;
            break;
        }
        if (first_idx == null) return;
        const first_op = block.instructions[first_idx.?].opcode;
        if (first_op == .POP_TOP or first_op == .JUMP_FORWARD or first_op == .JUMP_BACKWARD or
            first_op == .JUMP_BACKWARD_NO_INTERRUPT or first_op == .JUMP_ABSOLUTE)
        {
            return;
        }
        const end_idx = self.matchPreludeEnd(block);
        if (end_idx == 0 or end_idx <= first_idx.?) return;
        var tmp = block.*;
        tmp.instructions = block.instructions[0..end_idx];
        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        try self.processBlockWithSimAndSkip(&tmp, &sim, stmts, stmts_allocator, 0);
    }

    fn guardExprFromBlock(self: *Decompiler, block: *const cfg_mod.BasicBlock) DecompileError!?*Expr {
        var guard: ?*Expr = null;
        var guard_start: ?usize = null;

        // Store-based guard patterns
        for (block.instructions, 0..) |inst, i| {
            if (inst.opcode == .STORE_FAST_STORE_FAST) {
                for (block.instructions[i + 1 ..], i + 1..) |next, j| {
                    if (next.opcode == .LOAD_GLOBAL or next.opcode == .LOAD_NAME or
                        next.opcode == .LOAD_FAST_BORROW or next.opcode == .LOAD_FAST or
                        next.opcode == .LOAD_FAST_BORROW_LOAD_FAST_BORROW or next.opcode == .LOAD_FAST_LOAD_FAST)
                    {
                        guard_start = j;
                        break;
                    }
                }
                break;
            } else if (inst.opcode == .STORE_FAST_LOAD_FAST) {
                const a = self.arena.allocator();
                var sim = self.initSim(a, a, self.code, self.version);
                defer sim.deinit();

                const load_idx = inst.arg & 0xF;
                if (load_idx < self.code.varnames.len) {
                    const name = self.code.varnames[load_idx];
                    const expr = try self.makeName(name, .load);
                    try sim.stack.push(.{ .expr = expr });

                    for (block.instructions[i + 1 ..]) |g_inst| {
                        if (g_inst.opcode == .POP_JUMP_IF_FALSE or g_inst.opcode == .POP_JUMP_FORWARD_IF_FALSE) break;
                        try sim.simulate(g_inst);
                    }
                    guard = try sim.stack.popExpr();
                }
                return guard;
            } else if (inst.opcode == .STORE_NAME or inst.opcode == .STORE_FAST) {
                var found_guard = false;
                for (block.instructions[i + 1 ..], i + 1..) |next_inst, j| {
                    if (next_inst.opcode == .LOAD_NAME or next_inst.opcode == .LOAD_FAST or
                        next_inst.opcode == .LOAD_FAST_BORROW or next_inst.opcode == .LOAD_FAST_BORROW_LOAD_FAST_BORROW or
                        next_inst.opcode == .LOAD_FAST_LOAD_FAST)
                    {
                        const same_var = if (inst.opcode == .STORE_NAME and next_inst.opcode == .LOAD_NAME)
                            inst.arg == next_inst.arg
                        else if (inst.opcode == .STORE_FAST and (next_inst.opcode == .LOAD_FAST or next_inst.opcode == .LOAD_FAST_BORROW))
                            inst.arg == next_inst.arg
                        else
                            false;

                        if (same_var) {
                            const a = self.arena.allocator();
                            var sim = self.initSim(a, a, self.code, self.version);
                            defer sim.deinit();
                            for (block.instructions[j..]) |g_inst| {
                                if (g_inst.opcode == .POP_JUMP_IF_FALSE or g_inst.opcode == .POP_JUMP_FORWARD_IF_FALSE) break;
                                try sim.simulate(g_inst);
                            }
                            guard = try sim.stack.popExpr();
                            found_guard = true;
                            break;
                        }
                    }
                }
                if (found_guard) return guard;
            }
        }

        if (guard_start) |start| {
            const a = self.arena.allocator();
            var sim = self.initSim(a, a, self.code, self.version);
            defer sim.deinit();
            for (block.instructions[start..]) |g_inst| {
                if (g_inst.opcode == .POP_JUMP_IF_FALSE or g_inst.opcode == .POP_JUMP_FORWARD_IF_FALSE) break;
                try sim.simulate(g_inst);
            }
            guard = try sim.stack.popExpr();
            if (guard != null) return guard;
        }

        // Guard-only block: no pattern ops, no GET_LEN, but has conditional jump
        var has_get_len = false;
        var has_pat_op = false;
        var has_cond = false;
        if (block.terminator()) |term| {
            has_cond = ctrl.Analyzer.isConditionalJump(undefined, term.opcode);
        }
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .GET_LEN => has_get_len = true,
                .MATCH_SEQUENCE, .MATCH_MAPPING, .MATCH_CLASS, .MATCH_KEYS, .UNPACK_SEQUENCE, .STORE_FAST_STORE_FAST, .STORE_FAST_LOAD_FAST, .STORE_FAST, .STORE_NAME => has_pat_op = true,
                else => {},
            }
        }

        if (!has_cond or has_pat_op or has_get_len) return null;

        var start_idx: ?usize = null;
        for (block.instructions, 0..) |inst, i| {
            if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
            start_idx = i;
            break;
        }
        if (start_idx == null) return null;

        const a = self.arena.allocator();
        var sim = self.initSim(a, a, self.code, self.version);
        defer sim.deinit();
        for (block.instructions[start_idx.?..]) |g_inst| {
            if (g_inst.opcode == .POP_JUMP_IF_FALSE or g_inst.opcode == .POP_JUMP_FORWARD_IF_FALSE) break;
            try sim.simulate(g_inst);
        }
        return try sim.stack.popExpr();
    }

    fn guardStartInBlock(self: *Decompiler, block: *const cfg_mod.BasicBlock) DecompileError!?GuardStart {
        var has_cond = false;
        if (block.terminator()) |term| {
            has_cond = ctrl.Analyzer.isConditionalJump(undefined, term.opcode);
        }

        var seen_match = false;
        for (block.instructions, 0..) |inst, i| {
            switch (inst.opcode) {
                .MATCH_SEQUENCE, .MATCH_MAPPING, .MATCH_CLASS, .MATCH_KEYS, .UNPACK_SEQUENCE, .COPY, .GET_LEN, .STORE_FAST_LOAD_FAST, .STORE_FAST_STORE_FAST => seen_match = true,
                .COMPARE_OP => seen_match = true,
                else => {},
            }
            if (inst.opcode == .STORE_FAST_LOAD_FAST) {
                if (!seen_match) continue;
                const load_idx = inst.arg & 0xF;
                if (load_idx >= self.code.varnames.len) return null;
                const name = self.code.varnames[load_idx];
                const expr = try self.makeName(name, .load);
                return .{ .idx = i + 1, .preload = expr };
            }
            if (inst.opcode == .STORE_FAST_STORE_FAST) {
                if (!seen_match) continue;
                var preload: ?*Expr = null;
                var j = i + 1;
                while (j < block.instructions.len) : (j += 1) {
                    const op = block.instructions[j].opcode;
                    if (op == .STORE_FAST_LOAD_FAST) {
                        const load_idx = block.instructions[j].arg & 0xF;
                        if (load_idx < self.code.varnames.len) {
                            const name = self.code.varnames[load_idx];
                            preload = try self.makeName(name, .load);
                        }
                        continue;
                    }
                    if (op == .LOAD_GLOBAL or op == .LOAD_NAME or op == .LOAD_FAST or
                        op == .LOAD_FAST_BORROW or op == .LOAD_FAST_LOAD_FAST or
                        op == .LOAD_FAST_BORROW_LOAD_FAST_BORROW)
                    {
                        return .{ .idx = j, .preload = preload };
                    }
                    if (ctrl.Analyzer.isConditionalJump(undefined, op)) break;
                }
                return null;
            }
            if (inst.opcode == .STORE_FAST or inst.opcode == .STORE_NAME) {
                if (!seen_match) continue;
                const store_idx = inst.arg;
                var j = i + 1;
                while (j < block.instructions.len) : (j += 1) {
                    const op = block.instructions[j].opcode;
                    if (inst.opcode == .STORE_FAST and (op == .LOAD_FAST or op == .LOAD_FAST_BORROW) and block.instructions[j].arg == store_idx) {
                        return .{ .idx = j, .preload = null };
                    }
                    if (inst.opcode == .STORE_NAME and op == .LOAD_NAME and block.instructions[j].arg == store_idx) {
                        return .{ .idx = j, .preload = null };
                    }
                    if (ctrl.Analyzer.isConditionalJump(undefined, op)) break;
                }
            }
        }

        // Guard-only block: no pattern ops, no GET_LEN, but has conditional jump
        var has_pat_op = false;
        var has_match_op = false;
        var has_get_len = false;
        var has_lit_cmp = false;
        var has_copy = false;
        var has_subject_load = false;
        var prev_get_len = false;
        for (block.instructions, 0..) |inst, idx| {
            switch (inst.opcode) {
                .GET_LEN => {
                    has_get_len = true;
                    prev_get_len = true;
                },
                .COPY => has_copy = true,
                .LOAD_FAST, .LOAD_FAST_BORROW, .LOAD_FAST_LOAD_FAST, .LOAD_FAST_BORROW_LOAD_FAST_BORROW, .LOAD_NAME, .LOAD_GLOBAL, .LOAD_DEREF => has_subject_load = true,
                .MATCH_SEQUENCE, .MATCH_MAPPING, .MATCH_CLASS, .MATCH_KEYS => {
                    has_match_op = true;
                    has_pat_op = true;
                },
                .UNPACK_SEQUENCE, .STORE_FAST_STORE_FAST, .STORE_FAST_LOAD_FAST, .STORE_FAST, .STORE_NAME => has_pat_op = true,
                .LOAD_CONST, .LOAD_SMALL_INT => {
                    if (!prev_get_len) {
                        var j = idx + 1;
                        while (j < block.instructions.len) : (j += 1) {
                            const op = block.instructions[j].opcode;
                            if (op == .NOT_TAKEN or op == .CACHE) continue;
                            if (op == .COMPARE_OP) has_lit_cmp = true;
                            break;
                        }
                    }
                    prev_get_len = false;
                },
                else => prev_get_len = false,
            }
        }
        if (has_lit_cmp and (has_copy or !has_subject_load)) {
            has_pat_op = true;
        }
        if (has_cond and has_lit_cmp and !has_match_op and !has_get_len) {
            var seen_match2 = false;
            var first_jump: ?usize = null;
            for (block.instructions, 0..) |inst, i| {
                if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                switch (inst.opcode) {
                    .COMPARE_OP, .COPY, .LOAD_CONST, .LOAD_SMALL_INT => seen_match2 = true,
                    else => {},
                }
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode) and seen_match2) {
                    first_jump = i;
                    break;
                }
            }
            if (first_jump) |fj| {
                var has_second = false;
                var k = fj + 1;
                while (k < block.instructions.len) : (k += 1) {
                    const op = block.instructions[k].opcode;
                    if (op == .NOT_TAKEN or op == .CACHE) continue;
                    if (ctrl.Analyzer.isConditionalJump(undefined, op)) {
                        has_second = true;
                        break;
                    }
                }
                if (has_second) {
                    var j = fj + 1;
                    while (j < block.instructions.len) : (j += 1) {
                        const op = block.instructions[j].opcode;
                        if (op == .NOT_TAKEN or op == .CACHE) continue;
                        return .{ .idx = j, .preload = null };
                    }
                }
            }
        }
        if (!has_cond or has_pat_op or has_get_len) return null;

        for (block.instructions, 0..) |inst, i| {
            if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
            return .{ .idx = i, .preload = null };
        }
        return null;
    }

    fn guardCondFromJump(self: *Decompiler, cond: *Expr, op: Opcode) DecompileError!*Expr {
        return switch (op) {
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_TRUE,
            => try self.invertConditionExpr(cond),
            .POP_JUMP_IF_NONE,
            .POP_JUMP_FORWARD_IF_NONE,
            .POP_JUMP_BACKWARD_IF_NONE,
            => try self.makeIsNoneCompare(cond, true),
            .POP_JUMP_IF_NOT_NONE,
            .POP_JUMP_FORWARD_IF_NOT_NONE,
            .POP_JUMP_BACKWARD_IF_NOT_NONE,
            => try self.makeIsNoneCompare(cond, false),
            else => cond,
        };
    }

    fn guardCondForBranch(self: *Decompiler, cond: *Expr, op: Opcode, taken: bool) DecompileError!*Expr {
        return switch (op) {
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_FORWARD_IF_FALSE,
            .POP_JUMP_BACKWARD_IF_FALSE,
            .JUMP_IF_FALSE,
            => if (taken) try self.invertConditionExpr(cond) else cond,
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_TRUE,
            .JUMP_IF_TRUE,
            => if (taken) cond else try self.invertConditionExpr(cond),
            .POP_JUMP_IF_NONE,
            .POP_JUMP_FORWARD_IF_NONE,
            .POP_JUMP_BACKWARD_IF_NONE,
            => if (taken) try self.makeIsNoneCompare(cond, true) else try self.makeIsNoneCompare(cond, false),
            .POP_JUMP_IF_NOT_NONE,
            .POP_JUMP_FORWARD_IF_NOT_NONE,
            .POP_JUMP_BACKWARD_IF_NOT_NONE,
            => if (taken) try self.makeIsNoneCompare(cond, false) else try self.makeIsNoneCompare(cond, true),
            else => if (taken) cond else try self.invertConditionExpr(cond),
        };
    }

    fn isTrueJump(self: *Decompiler, op: Opcode) bool {
        _ = self;
        return switch (op) {
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_TRUE,
            .JUMP_IF_TRUE,
            => true,
            else => false,
        };
    }

    fn elseIsJumpTarget(self: *Decompiler, op: Opcode) bool {
        _ = self;
        return switch (op) {
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_FORWARD_IF_FALSE,
            .POP_JUMP_BACKWARD_IF_FALSE,
            .JUMP_IF_FALSE,
            .POP_JUMP_IF_NONE,
            .POP_JUMP_FORWARD_IF_NONE,
            .POP_JUMP_BACKWARD_IF_NONE,
            .POP_JUMP_IF_NOT_NONE,
            .POP_JUMP_FORWARD_IF_NOT_NONE,
            .POP_JUMP_BACKWARD_IF_NOT_NONE,
            .JUMP_IF_FALSE_OR_POP,
            => true,
            else => false,
        };
    }

    fn isContGuard(self: *Decompiler, stmt: *const Stmt, cond: *const Expr) bool {
        _ = self;
        if (stmt.* != .if_stmt) return false;
        const ifs = stmt.if_stmt;
        if (ifs.else_body.len != 0) return false;
        if (ifs.body.len != 1 or ifs.body[0].* != .continue_stmt) return false;
        return ast.exprEqual(ifs.condition, cond);
    }

    fn isFalseJump(self: *Decompiler, op: Opcode) bool {
        _ = self;
        return switch (op) {
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_FORWARD_IF_FALSE,
            .POP_JUMP_BACKWARD_IF_FALSE,
            .JUMP_IF_FALSE,
            => true,
            else => false,
        };
    }

    fn invertJumpOpcode(self: *Decompiler, op: Opcode) Opcode {
        _ = self;
        return switch (op) {
            .POP_JUMP_IF_TRUE => .POP_JUMP_IF_FALSE,
            .POP_JUMP_FORWARD_IF_TRUE => .POP_JUMP_FORWARD_IF_FALSE,
            .POP_JUMP_BACKWARD_IF_TRUE => .POP_JUMP_BACKWARD_IF_FALSE,
            .JUMP_IF_TRUE => .JUMP_IF_FALSE,
            .POP_JUMP_IF_FALSE => .POP_JUMP_IF_TRUE,
            .POP_JUMP_FORWARD_IF_FALSE => .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_FALSE => .POP_JUMP_BACKWARD_IF_TRUE,
            .JUMP_IF_FALSE => .JUMP_IF_TRUE,
            else => op,
        };
    }

    fn guardExprsFromBlocks(self: *Decompiler, blocks: []const u32) DecompileError![]const *Expr {
        var guard_exprs: std.ArrayList(*Expr) = .{};
        errdefer guard_exprs.deinit(self.allocator);

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();

        for (blocks) |bid| {
            const blk = &self.cfg.blocks[bid];
            const start = (try self.guardStartInBlock(blk)) orelse continue;
            if (start.preload) |e| {
                try sim.stack.push(.{ .expr = e });
            }

            var i = start.idx;
            while (i < blk.instructions.len) : (i += 1) {
                const inst = blk.instructions[i];
                switch (inst.opcode) {
                    .NOT_TAKEN, .CACHE => continue,
                    .STORE_FAST_LOAD_FAST => {
                        const load_idx = inst.arg & 0xF;
                        if (load_idx < self.code.varnames.len) {
                            const name = self.code.varnames[load_idx];
                            const expr = try self.makeName(name, .load);
                            try sim.stack.push(.{ .expr = expr });
                        } else {
                            try sim.stack.push(.unknown);
                        }
                        continue;
                    },
                    .STORE_FAST_STORE_FAST, .MATCH_SEQUENCE, .MATCH_MAPPING, .MATCH_CLASS, .MATCH_KEYS, .UNPACK_SEQUENCE, .GET_LEN, .STORE_FAST, .STORE_NAME => continue,
                    .POP_TOP => {
                        if (sim.stack.len() > 0) {
                            _ = sim.stack.pop();
                        }
                        continue;
                    },
                    .POP_JUMP_IF_TRUE,
                    .POP_JUMP_IF_FALSE,
                    .POP_JUMP_IF_NONE,
                    .POP_JUMP_IF_NOT_NONE,
                    .POP_JUMP_FORWARD_IF_TRUE,
                    .POP_JUMP_FORWARD_IF_FALSE,
                    .POP_JUMP_FORWARD_IF_NONE,
                    .POP_JUMP_FORWARD_IF_NOT_NONE,
                    .POP_JUMP_BACKWARD_IF_TRUE,
                    .POP_JUMP_BACKWARD_IF_FALSE,
                    .POP_JUMP_BACKWARD_IF_NONE,
                    .POP_JUMP_BACKWARD_IF_NOT_NONE,
                    => {
                        const cond = try sim.stack.popExpr();
                        const final_cond = try self.guardCondFromJump(cond, inst.opcode);
                        try guard_exprs.append(self.allocator, final_cond);
                        continue;
                    },
                    .JUMP_FORWARD, .JUMP_BACKWARD, .JUMP_ABSOLUTE => continue,
                    else => {
                        try sim.simulate(inst);
                    },
                }
            }
        }

        const out = try self.arena.allocator().dupe(*Expr, guard_exprs.items);
        guard_exprs.deinit(self.allocator);
        return out;
    }

    fn isSimpleReturnBlock(self: *Decompiler, block_id: u32) bool {
        if (block_id >= self.cfg.blocks.len) return false;
        const blk = &self.cfg.blocks[block_id];
        var has_return = false;
        for (blk.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) return false;
            switch (inst.opcode) {
                .MATCH_SEQUENCE, .MATCH_MAPPING, .MATCH_CLASS, .MATCH_KEYS, .COPY, .STORE_FAST_LOAD_FAST, .STORE_FAST_STORE_FAST => return false,
                .RETURN_VALUE, .RETURN_CONST => has_return = true,
                else => {},
            }
        }
        return has_return;
    }

    fn succEdgeForJump(op: Opcode) cfg_mod.EdgeType {
        return switch (op) {
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_TRUE,
            .POP_JUMP_IF_NOT_NONE,
            .POP_JUMP_FORWARD_IF_NOT_NONE,
            .POP_JUMP_BACKWARD_IF_NOT_NONE,
            .JUMP_IF_TRUE_OR_POP,
            .JUMP_IF_TRUE,
            => .conditional_false,
            else => .conditional_true,
        };
    }

    fn failEdgeForJump(op: Opcode) cfg_mod.EdgeType {
        return if (succEdgeForJump(op) == .conditional_true) .conditional_false else .conditional_true;
    }

    fn maxLeadPop(self: *Decompiler, start: u32, end: u32) usize {
        var max: usize = 0;
        var b = start;
        const limit = @min(end, @as(u32, @intCast(self.cfg.blocks.len)));
        while (b < limit) : (b += 1) {
            const blk = &self.cfg.blocks[b];
            var cnt: usize = 0;
            for (blk.instructions) |inst| {
                if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                if (inst.opcode == .POP_TOP) {
                    cnt += 1;
                    continue;
                }
                break;
            }
            if (cnt > max) max = cnt;
        }
        return max;
    }

    const GuardStart = struct {
        idx: usize,
        preload: ?*Expr,
    };

    fn makeIsNoneCompare(self: *Decompiler, value: *Expr, is_not: bool) DecompileError!*Expr {
        const a = self.arena.allocator();
        const none_expr = try ast.makeConstant(a, .{ .none = {} });
        const comparators = try a.alloc(*Expr, 1);
        comparators[0] = none_expr;
        const ops = try a.alloc(ast.CmpOp, 1);
        ops[0] = if (is_not) .is_not else .is;
        const expr = try a.create(Expr);
        expr.* = .{ .compare = .{ .left = value, .ops = ops, .comparators = comparators } };
        return expr;
    }

    fn invertCompareOp(op: ast.CmpOp) ?ast.CmpOp {
        return switch (op) {
            .eq => .not_eq,
            .not_eq => .eq,
            .lt => .gte,
            .lte => .gt,
            .gt => .lte,
            .gte => .lt,
            .is => .is_not,
            .is_not => .is,
            .in_ => .not_in,
            .not_in => .in_,
        };
    }

    fn invertConditionExpr(self: *Decompiler, expr: *Expr) DecompileError!*Expr {
        if (expr.* == .unary_op and expr.unary_op.op == .not_) {
            return expr.unary_op.operand;
        }
        if (expr.* == .compare) {
            const cmp = expr.compare;
            if (cmp.ops.len == 1 and cmp.comparators.len == 1) {
                if (invertCompareOp(cmp.ops[0])) |inv| {
                    const a = self.arena.allocator();
                    const ops = try a.alloc(ast.CmpOp, 1);
                    ops[0] = inv;
                    const comps = try a.alloc(*Expr, 1);
                    comps[0] = cmp.comparators[0];
                    const out = try a.create(Expr);
                    out.* = .{ .compare = .{ .left = cmp.left, .ops = ops, .comparators = comps } };
                    return out;
                }
            }
        }
        return ast.makeUnaryOp(self.arena.allocator(), .not_, expr);
    }

    fn sameExpr(self: *Decompiler, left: *const Expr, right: *const Expr) bool {
        _ = self;
        return ast.exprEqual(left, right);
    }

    fn sameAugAssignTarget(self: *Decompiler, target: *const Expr, left: *const Expr) bool {
        _ = self;
        return switch (target.*) {
            .name => left.* == .name and std.mem.eql(u8, target.name.id, left.name.id),
            .attribute => left.* == .attribute and std.mem.eql(u8, target.attribute.attr, left.attribute.attr) and
                ast.exprEqual(target.attribute.value, left.attribute.value),
            .subscript => left.* == .subscript and ast.exprEqual(target.subscript.value, left.subscript.value) and
                ast.exprEqual(target.subscript.slice, left.subscript.slice),
            else => ast.exprEqual(target, left),
        };
    }

    fn tryMakeAugAssign(
        self: *Decompiler,
        sim: *SimContext,
        target: *Expr,
        value: *Expr,
    ) DecompileError!?*Stmt {
        if (value.* != .bin_op) return null;
        if (!sim.isInplaceExpr(value)) return null;
        const binop = value.bin_op;
        if (!self.sameAugAssignTarget(target, binop.left)) return null;

        const a = self.arena.allocator();
        binop.left.deinit(a);
        a.destroy(binop.left);

        const stmt = try a.create(Stmt);
        stmt.* = .{ .aug_assign = .{
            .target = target,
            .op = binop.op,
            .value = binop.right,
        } };
        a.destroy(value);
        return stmt;
    }

    fn mergeCompareChain(self: *Decompiler, left: *Expr, right: *Expr) DecompileError!?*Expr {
        if (left.* != .compare or right.* != .compare) return null;
        const l = left.compare;
        const r = right.compare;
        if (l.comparators.len == 0 or r.comparators.len == 0) return null;
        const last = l.comparators[l.comparators.len - 1];
        if (!self.sameExpr(last, r.left)) return null;

        const a = self.arena.allocator();
        const ops = try a.alloc(ast.CmpOp, l.ops.len + r.ops.len);
        const comps = try a.alloc(*Expr, l.comparators.len + r.comparators.len);
        std.mem.copyForwards(ast.CmpOp, ops[0..l.ops.len], l.ops);
        std.mem.copyForwards(ast.CmpOp, ops[l.ops.len..], r.ops);
        std.mem.copyForwards(*Expr, comps[0..l.comparators.len], l.comparators);
        std.mem.copyForwards(*Expr, comps[l.comparators.len..], r.comparators);

        const expr = try a.create(Expr);
        expr.* = .{ .compare = .{ .left = l.left, .ops = ops, .comparators = comps } };
        return expr;
    }

    const ClassInfo = struct {
        cls: *Expr,
        attrs: []const []const u8,
    };

    const MatchCaseResult = struct {
        case: ast.MatchCase,
        fallback_body: ?[]const *Stmt,
        fallback_block: ?u32,
    };

    const SeqBuild = struct {
        expected: usize,
        items: std.ArrayListUnmanaged(*ast.Pattern) = .{},
        swap: bool = false,
    };

    fn constExprFromObj(self: *Decompiler, obj: pyc.Object) DecompileError!*Expr {
        const a = self.arena.allocator();
        return switch (obj) {
            .none => ast.makeConstant(a, .{ .none = {} }),
            .true_val => ast.makeConstant(a, .{ .true_ = {} }),
            .false_val => ast.makeConstant(a, .{ .false_ = {} }),
            .ellipsis => ast.makeConstant(a, .{ .ellipsis = {} }),
            .string => |s| ast.makeConstant(a, .{ .string = s }),
            .bytes => |b| ast.makeConstant(a, .{ .bytes = b }),
            .int => |i| switch (i) {
                .small => |v| ast.makeConstant(a, .{ .int = v }),
                .big => |b| ast.makeConstant(a, .{ .big_int = try b.clone(a) }),
            },
            .float => |f| ast.makeConstant(a, .{ .float = f }),
            .complex => |c| ast.makeConstant(a, .{ .complex = .{ .real = c.real, .imag = c.imag } }),
            else => error.InvalidBlock,
        };
    }

    fn keyExprsFromObj(self: *Decompiler, obj: pyc.Object) DecompileError!?[]const *Expr {
        const a = self.arena.allocator();
        switch (obj) {
            .tuple => |items| {
                const exprs = try a.alloc(*Expr, items.len);
                for (items, 0..) |item, i| {
                    exprs[i] = try self.constExprFromObj(item);
                }
                return exprs;
            },
            else => return null,
        }
    }

    fn attrNamesFromObj(self: *Decompiler, obj: pyc.Object) DecompileError!?[]const []const u8 {
        const a = self.arena.allocator();
        switch (obj) {
            .tuple => |items| {
                const names = try a.alloc([]const u8, items.len);
                for (items, 0..) |item, i| {
                    switch (item) {
                        .string => |s| names[i] = try self.unmangleClassName(s),
                        else => return null,
                    }
                }
                return names;
            },
            else => return null,
        }
    }

    fn findAsName(self: *Decompiler, insts: []const cfg_mod.Instruction, start_idx: usize) ?[]const u8 {
        var i = start_idx + 1;
        while (i < insts.len) : (i += 1) {
            const op = insts[i].opcode;
            if (op == .NOT_TAKEN or op == .CACHE) continue;
            switch (op) {
                .POP_JUMP_IF_FALSE,
                .POP_JUMP_FORWARD_IF_FALSE,
                .POP_JUMP_IF_TRUE,
                .POP_JUMP_FORWARD_IF_TRUE,
                .POP_JUMP_IF_NONE,
                .POP_JUMP_FORWARD_IF_NONE,
                => break,
                .LOAD_FAST_BORROW,
                .LOAD_FAST_BORROW_LOAD_FAST_BORROW,
                .LOAD_FAST_LOAD_FAST,
                .LOAD_FAST,
                .LOAD_GLOBAL,
                .LOAD_NAME,
                => break,
                .STORE_FAST => return self.code.varnames[insts[i].arg],
                .STORE_NAME => return self.code.names[insts[i].arg],
                else => {},
            }
        }
        return null;
    }

    fn nextOp(insts: []const cfg_mod.Instruction, idx: usize) ?Opcode {
        var j = idx + 1;
        while (j < insts.len) : (j += 1) {
            const op = insts[j].opcode;
            if (op == .CACHE or op == .NOT_TAKEN) continue;
            return op;
        }
        return null;
    }

    fn indexOfBlock(blocks: []const u32, id: u32) ?usize {
        for (blocks, 0..) |b, i| {
            if (b == id) return i;
        }
        return null;
    }

    fn jumpTargetIfJumpOnly(self: *Decompiler, block_id: u32, allow_pop: bool) ?u32 {
        return self.jumpTargetIfJumpOnlyEdge(block_id, allow_pop, false);
    }

    fn jumpTargetIfJumpOnlyEdge(
        self: *Decompiler,
        block_id: u32,
        allow_pop: bool,
        allow_loop: bool,
    ) ?u32 {
        if (block_id >= self.cfg.blocks.len) return null;
        const blk = &self.cfg.blocks[block_id];
        if (blk.instructions.len == 0) {
            for (blk.successors) |edge| {
                if (edge.edge_type == .normal or (allow_loop and edge.edge_type == .loop_back)) {
                    return edge.target;
                }
            }
            return null;
        }
        var saw_jump = false;
        for (blk.instructions) |inst| {
            switch (inst.opcode) {
                .NOT_TAKEN, .CACHE => continue,
                .POP_TOP => {
                    if (allow_pop) continue;
                    return null;
                },
                .JUMP_FORWARD, .JUMP_BACKWARD, .JUMP_ABSOLUTE => {
                    if (saw_jump) return null;
                    saw_jump = true;
                    continue;
                },
                else => return null,
            }
        }
        if (!saw_jump) return null;
        for (blk.successors) |edge| {
            if (edge.edge_type == .normal or (allow_loop and edge.edge_type == .loop_back)) {
                return edge.target;
            }
        }
        return null;
    }

    fn literalPatternFromBlock(self: *Decompiler, blk: *const cfg_mod.BasicBlock) DecompileError!?*ast.Pattern {
        const a = self.arena.allocator();
        var lit_expr: ?*Expr = null;
        for (blk.instructions) |inst| {
            switch (inst.opcode) {
                .MATCH_SEQUENCE, .MATCH_MAPPING, .MATCH_CLASS, .MATCH_KEYS, .GET_LEN => return null,
                .LOAD_SMALL_INT => {
                    lit_expr = try ast.makeConstant(a, .{ .int = @intCast(inst.arg) });
                },
                .LOAD_CONST => {
                    const obj = self.code.consts[inst.arg];
                    if (self.constExprFromObj(obj)) |expr| {
                        lit_expr = expr;
                    } else |err| switch (err) {
                        error.InvalidBlock => return null,
                        else => return err,
                    }
                },
                .COMPARE_OP => {
                    if (lit_expr) |v| {
                        const pat = try a.create(ast.Pattern);
                        pat.* = .{ .match_value = v };
                        return pat;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn blocksEq(self: *Decompiler, a_id: u32, b_id: u32) bool {
        if (a_id >= self.cfg.blocks.len or b_id >= self.cfg.blocks.len) return false;
        const a_blk = &self.cfg.blocks[a_id];
        const b_blk = &self.cfg.blocks[b_id];
        var ai: usize = 0;
        var bi: usize = 0;
        while (true) {
            while (ai < a_blk.instructions.len) : (ai += 1) {
                const op = a_blk.instructions[ai].opcode;
                if (op == .NOT_TAKEN or op == .CACHE) continue;
                break;
            }
            while (bi < b_blk.instructions.len) : (bi += 1) {
                const op = b_blk.instructions[bi].opcode;
                if (op == .NOT_TAKEN or op == .CACHE) continue;
                break;
            }
            const a_end = ai >= a_blk.instructions.len;
            const b_end = bi >= b_blk.instructions.len;
            if (a_end or b_end) return a_end and b_end;
            const a_inst = a_blk.instructions[ai];
            const b_inst = b_blk.instructions[bi];
            if (a_inst.opcode != b_inst.opcode or a_inst.arg != b_inst.arg) return false;
            ai += 1;
            bi += 1;
        }
    }

    const OrChain = struct {
        guard_block: u32,
        next_idx: usize,
        patterns: []const *ast.Pattern,
        last_block: u32,
        fail_block: ?u32,
    };

    fn tryMatchOrChain(self: *Decompiler, case_blocks: []const u32, start_idx: usize) DecompileError!?OrChain {
        const a = self.arena.allocator();
        var patterns: std.ArrayList(*ast.Pattern) = .{};
        defer patterns.deinit(a);

        var success_target: ?u32 = null;
        var next_case_id: ?u32 = null;
        var last_fail: ?u32 = null;
        var idx = start_idx;
        while (idx < case_blocks.len) {
            const bid = case_blocks[idx];
            const blk = &self.cfg.blocks[bid];
            const pat = try self.literalPatternFromBlock(blk) orelse break;
            const term = blk.terminator() orelse break;
            if (!ctrl.Analyzer.isConditionalJump(undefined, term.opcode)) break;

            const succ_edge = succEdgeForJump(term.opcode);
            const fail_edge = failEdgeForJump(term.opcode);
            var true_block: ?u32 = null;
            var false_block: ?u32 = null;
            for (blk.successors) |edge| {
                if (edge.edge_type == succ_edge) true_block = edge.target;
                if (edge.edge_type == fail_edge) false_block = edge.target;
            }
            if (true_block == null or false_block == null) break;
            last_fail = false_block.?;

            var true_target: u32 = true_block.?;
            if (self.jumpTargetIfJumpOnly(true_block.?, false)) |target| {
                true_target = target;
            }
            if (success_target == null) {
                success_target = true_target;
            } else if (!self.blocksEq(success_target.?, true_target)) {
                break;
            }

            try patterns.append(a, pat);

            const next_idx = indexOfBlock(case_blocks, false_block.?) orelse {
                if (self.jumpTargetIfJumpOnly(false_block.?, true)) |target| {
                    next_case_id = target;
                }
                break;
            };
            if (next_idx <= idx) break;
            idx = next_idx;
        }

        if (patterns.items.len < 2 or success_target == null) return null;
        var next_idx: usize = case_blocks.len;
        if (next_case_id) |next_id| {
            next_idx = indexOfBlock(case_blocks, next_id) orelse case_blocks.len;
        } else if (idx + 1 <= case_blocks.len) {
            next_idx = idx + 1;
        }
        const pats = try patterns.toOwnedSlice(a);
        return OrChain{
            .guard_block = success_target.?,
            .next_idx = next_idx,
            .patterns = pats,
            .last_block = case_blocks[idx],
            .fail_block = last_fail,
        };
    }

    fn isWildcardPattern(pat: *const ast.Pattern) bool {
        return switch (pat.*) {
            .match_as => |a| a.pattern == null and a.name == null,
            else => false,
        };
    }

    fn mapPatternFromBlocks(self: *Decompiler, blocks: []const u32) DecompileError!?*ast.Pattern {
        const a = self.arena.allocator();
        var keys: ?[]const *Expr = null;
        var val_block: ?u32 = null;

        for (blocks) |bid| {
            const blk = &self.cfg.blocks[bid];
            for (blk.instructions, 0..) |inst, i| {
                if (inst.opcode != .MATCH_KEYS) continue;
                var j = i;
                while (j > 0) {
                    j -= 1;
                    const op = blk.instructions[j].opcode;
                    if (op == .NOT_TAKEN or op == .CACHE) continue;
                    if (op == .LOAD_CONST) {
                        const obj = self.code.consts[blk.instructions[j].arg];
                        keys = try self.keyExprsFromObj(obj);
                        break;
                    }
                    if (op == .MATCH_MAPPING) break;
                }
                if (blk.terminator()) |term| {
                    const succ_edge = succEdgeForJump(term.opcode);
                    for (blk.successors) |edge| {
                        if (edge.edge_type == succ_edge) {
                            val_block = edge.target;
                            break;
                        }
                    }
                }
                break;
            }
            if (keys != null and val_block != null) break;
        }

        if (keys == null or val_block == null) return null;
        const k = keys.?;
        if (k.len == 0) return null;

        const vblk = &self.cfg.blocks[val_block.?];
        var unpack_idx: ?usize = null;
        var count: usize = 0;
        for (vblk.instructions, 0..) |inst, i| {
            if (inst.opcode == .UNPACK_SEQUENCE) {
                unpack_idx = i;
                count = @intCast(inst.arg);
                break;
            }
        }
        if (unpack_idx == null or count != k.len) return null;

        const pats = try a.alloc(*ast.Pattern, k.len);
        var filled: usize = 0;
        var i = unpack_idx.? + 1;
        while (i < vblk.instructions.len and filled < k.len) : (i += 1) {
            const op = vblk.instructions[i].opcode;
            if (op == .NOT_TAKEN or op == .CACHE or op == .POP_TOP) continue;
            if (op == .STORE_FAST or op == .STORE_NAME) {
                const name = if (op == .STORE_NAME)
                    self.code.names[vblk.instructions[i].arg]
                else
                    self.code.varnames[vblk.instructions[i].arg];
                const unmangled = try self.unmangleClassName(name);
                const p = try a.create(ast.Pattern);
                p.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                pats[filled] = p;
                filled += 1;
                continue;
            }
            if (op == .STORE_FAST_STORE_FAST) {
                const idx1 = (vblk.instructions[i].arg >> 4) & 0xF;
                const idx2 = vblk.instructions[i].arg & 0xF;
                if (filled < k.len) {
                    const name1 = self.code.varnames[idx1];
                    const unmangled1 = try self.unmangleClassName(name1);
                    const p1 = try a.create(ast.Pattern);
                    p1.* = .{ .match_as = .{ .pattern = null, .name = unmangled1 } };
                    pats[filled] = p1;
                    filled += 1;
                }
                if (filled < k.len) {
                    const name2 = self.code.varnames[idx2];
                    const unmangled2 = try self.unmangleClassName(name2);
                    const p2 = try a.create(ast.Pattern);
                    p2.* = .{ .match_as = .{ .pattern = null, .name = unmangled2 } };
                    pats[filled] = p2;
                    filled += 1;
                }
                continue;
            }
            if (op == .LOAD_SMALL_INT or op == .LOAD_CONST) {
                const next_op = nextOp(vblk.instructions, i);
                if (next_op == .COMPARE_OP) {
                    const val_expr = if (op == .LOAD_SMALL_INT)
                        try ast.makeConstant(a, .{ .int = @intCast(vblk.instructions[i].arg) })
                    else
                        try self.constExprFromObj(self.code.consts[vblk.instructions[i].arg]);
                    const p = try a.create(ast.Pattern);
                    p.* = .{ .match_value = val_expr };
                    pats[filled] = p;
                    filled += 1;
                    continue;
                }
            }
            break;
        }

        if (filled != k.len) return null;
        const pat = try a.create(ast.Pattern);
        pat.* = .{ .match_mapping = .{ .keys = k, .patterns = pats, .rest = null } };
        return pat;
    }

    fn classPatternFromBlocks(self: *Decompiler, blocks: []const u32) DecompileError!?*ast.Pattern {
        const a = self.arena.allocator();
        var cls_expr: ?*Expr = null;
        var attrs: ?[]const []const u8 = null;
        var val_block: ?u32 = null;

        for (blocks) |bid| {
            const blk = &self.cfg.blocks[bid];
            var last_cls: ?*Expr = null;
            var last_attrs: ?[]const []const u8 = null;
            for (blk.instructions, 0..) |inst, i| {
                switch (inst.opcode) {
                    .LOAD_GLOBAL => {
                        if (inst.arg < self.code.names.len) {
                            const name = self.code.names[inst.arg];
                            last_cls = try self.makeName(name, .load);
                        }
                    },
                    .LOAD_NAME => {
                        if (inst.arg < self.code.names.len) {
                            const name = self.code.names[inst.arg];
                            last_cls = try self.makeName(name, .load);
                        }
                    },
                    .LOAD_FAST, .LOAD_FAST_BORROW => {
                        if (inst.arg < self.code.varnames.len) {
                            const name = self.code.varnames[inst.arg];
                            last_cls = try self.makeName(name, .load);
                        }
                    },
                    .LOAD_CONST => {
                        const obj = self.code.consts[inst.arg];
                        last_attrs = try self.attrNamesFromObj(obj);
                    },
                    .MATCH_CLASS => {
                        if (last_cls != null and last_attrs != null) {
                            cls_expr = last_cls;
                            attrs = last_attrs;
                            if (blk.terminator()) |term| {
                                const succ_edge = succEdgeForJump(term.opcode);
                                for (blk.successors) |edge| {
                                    if (edge.edge_type == succ_edge) {
                                        val_block = edge.target;
                                        break;
                                    }
                                }
                            }
                        }
                        _ = i;
                        break;
                    },
                    else => {},
                }
            }
            if (cls_expr != null and attrs != null and val_block != null) break;
        }

        if (cls_expr == null or attrs == null or val_block == null) return null;
        const attr_list = attrs.?;
        if (attr_list.len == 0) return null;

        const vblk = &self.cfg.blocks[val_block.?];
        var unpack_idx: ?usize = null;
        var count: usize = 0;
        for (vblk.instructions, 0..) |inst, i| {
            if (inst.opcode == .UNPACK_SEQUENCE) {
                unpack_idx = i;
                count = @intCast(inst.arg);
                break;
            }
        }
        if (unpack_idx == null or count != attr_list.len) return null;

        const pats = try a.alloc(*ast.Pattern, attr_list.len);
        var filled: usize = 0;
        var i = unpack_idx.? + 1;
        while (i < vblk.instructions.len and filled < attr_list.len) : (i += 1) {
            const op = vblk.instructions[i].opcode;
            if (op == .NOT_TAKEN or op == .CACHE or op == .POP_TOP) continue;
            if (op == .STORE_FAST or op == .STORE_NAME) {
                const name = if (op == .STORE_NAME)
                    self.code.names[vblk.instructions[i].arg]
                else
                    self.code.varnames[vblk.instructions[i].arg];
                const unmangled = try self.unmangleClassName(name);
                const p = try a.create(ast.Pattern);
                p.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                pats[filled] = p;
                filled += 1;
                continue;
            }
            if (op == .STORE_FAST_STORE_FAST and attr_list.len == 2) {
                const idx1 = (vblk.instructions[i].arg >> 4) & 0xF;
                const idx2 = vblk.instructions[i].arg & 0xF;
                const name1 = self.code.varnames[idx1];
                const name2 = self.code.varnames[idx2];
                const unmangled1 = try self.unmangleClassName(name1);
                const unmangled2 = try self.unmangleClassName(name2);
                const p1 = try a.create(ast.Pattern);
                p1.* = .{ .match_as = .{ .pattern = null, .name = unmangled1 } };
                const p2 = try a.create(ast.Pattern);
                p2.* = .{ .match_as = .{ .pattern = null, .name = unmangled2 } };
                pats[filled] = p1;
                pats[filled + 1] = p2;
                filled += 2;
                continue;
            }
            if (op == .LOAD_SMALL_INT or op == .LOAD_CONST) {
                const next_op = nextOp(vblk.instructions, i);
                if (next_op == .COMPARE_OP) {
                    const val_expr = if (op == .LOAD_SMALL_INT)
                        try ast.makeConstant(a, .{ .int = @intCast(vblk.instructions[i].arg) })
                    else
                        try self.constExprFromObj(self.code.consts[vblk.instructions[i].arg]);
                    const p = try a.create(ast.Pattern);
                    p.* = .{ .match_value = val_expr };
                    pats[filled] = p;
                    filled += 1;
                    continue;
                }
            }
            break;
        }

        if (filled != attr_list.len) {
            var all_insts: std.ArrayList(cfg_mod.Instruction) = .{};
            defer all_insts.deinit(self.allocator);
            for (blocks) |bid| {
                const blk = &self.cfg.blocks[bid];
                try all_insts.appendSlice(self.allocator, blk.instructions);
            }

            var u_idx: ?usize = null;
            var u_count: usize = 0;
            for (all_insts.items, 0..) |inst, j| {
                if (inst.opcode == .UNPACK_SEQUENCE) {
                    u_idx = j;
                    u_count = @intCast(inst.arg);
                    break;
                }
            }
            if (u_idx == null or u_count != attr_list.len) return null;

            const pats2 = try a.alloc(*ast.Pattern, attr_list.len);
            var filled2: usize = 0;
            var k: usize = u_idx.? + 1;
            while (k < all_insts.items.len and filled2 < attr_list.len) : (k += 1) {
                const op = all_insts.items[k].opcode;
                if (op == .NOT_TAKEN or op == .CACHE or op == .POP_TOP) continue;
                if (op == .COMPARE_OP or ctrl.Analyzer.isConditionalJump(undefined, op)) continue;
                if (op == .STORE_FAST or op == .STORE_NAME) {
                    const name = if (op == .STORE_NAME)
                        self.code.names[all_insts.items[k].arg]
                    else
                        self.code.varnames[all_insts.items[k].arg];
                    const unmangled = try self.unmangleClassName(name);
                    const p = try a.create(ast.Pattern);
                    p.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                    pats2[filled2] = p;
                    filled2 += 1;
                    continue;
                }
                if (op == .STORE_FAST_STORE_FAST and attr_list.len >= 2) {
                    const idx1 = (all_insts.items[k].arg >> 4) & 0xF;
                    const idx2 = all_insts.items[k].arg & 0xF;
                    const name1 = self.code.varnames[idx1];
                    const name2 = self.code.varnames[idx2];
                    const unmangled1 = try self.unmangleClassName(name1);
                    const unmangled2 = try self.unmangleClassName(name2);
                    const p1 = try a.create(ast.Pattern);
                    p1.* = .{ .match_as = .{ .pattern = null, .name = unmangled1 } };
                    const p2 = try a.create(ast.Pattern);
                    p2.* = .{ .match_as = .{ .pattern = null, .name = unmangled2 } };
                    if (filled2 < attr_list.len) {
                        pats2[filled2] = p1;
                        filled2 += 1;
                    }
                    if (filled2 < attr_list.len) {
                        pats2[filled2] = p2;
                        filled2 += 1;
                    }
                    continue;
                }
                if (op == .LOAD_SMALL_INT or op == .LOAD_CONST) {
                    const next_op = nextOp(all_insts.items, k);
                    if (next_op == .COMPARE_OP) {
                        const val_expr = if (op == .LOAD_SMALL_INT)
                            try ast.makeConstant(a, .{ .int = @intCast(all_insts.items[k].arg) })
                        else
                            try self.constExprFromObj(self.code.consts[all_insts.items[k].arg]);
                        const p = try a.create(ast.Pattern);
                        p.* = .{ .match_value = val_expr };
                        pats2[filled2] = p;
                        filled2 += 1;
                        continue;
                    }
                }
                break;
            }
            if (filled2 != attr_list.len) return null;

            const pat = try a.create(ast.Pattern);
            pat.* = .{ .match_class = .{
                .cls = cls_expr.?,
                .patterns = &.{},
                .kwd_attrs = attr_list,
                .kwd_patterns = pats2,
            } };
            return pat;
        }
        const pat = try a.create(ast.Pattern);
        pat.* = .{ .match_class = .{
            .cls = cls_expr.?,
            .patterns = &.{},
            .kwd_attrs = attr_list,
            .kwd_patterns = pats,
        } };
        return pat;
    }

    fn finishSeq(self: *Decompiler, seq_stack: *std.ArrayListUnmanaged(SeqBuild)) DecompileError!?*ast.Pattern {
        const a = self.arena.allocator();
        var out: ?*ast.Pattern = null;
        while (seq_stack.items.len > 0) {
            const last_idx = seq_stack.items.len - 1;
            const sb = &seq_stack.items[last_idx];
            if (sb.items.items.len != sb.expected) break;

            const seq_items = try a.alloc(*ast.Pattern, sb.items.items.len);
            std.mem.copyForwards(*ast.Pattern, seq_items, sb.items.items);
            if (sb.swap and seq_items.len == 2) {
                const tmp = seq_items[0];
                seq_items[0] = seq_items[1];
                seq_items[1] = tmp;
            }

            const seq_pat = try a.create(ast.Pattern);
            seq_pat.* = .{ .match_sequence = seq_items };

            sb.items.deinit(self.allocator);
            seq_stack.items.len -= 1;

            if (seq_stack.items.len == 0) {
                out = seq_pat;
                break;
            } else {
                try seq_stack.items[seq_stack.items.len - 1].items.append(self.allocator, seq_pat);
            }
        }
        return out;
    }

    fn decompileMatchCase(self: *Decompiler, block_id: u32, has_copy: bool) DecompileError!MatchCaseResult {
        // Pattern matching with guards spans multiple blocks:
        // Block N: MATCH_SEQUENCE, POP_JUMP -> pattern fail
        // Block N+1: GET_LEN, COMPARE_OP, POP_JUMP -> pattern fail
        // Block N+2: UNPACK, STORE_FAST_STORE_FAST, guard, POP_JUMP -> guard fail
        // Block N+3: body
        //
        // Need to collect all pattern+guard blocks by following conditional_true edges
        // until we reach the body block.

        var pattern_blocks: std.ArrayList(u32) = .{};
        defer pattern_blocks.deinit(self.allocator);

        var current_block_id = block_id;
        var last_test: u32 = block_id;
        var test_blocks: std.ArrayList(u32) = .{};
        defer test_blocks.deinit(self.allocator);

        // Follow conditional edges while blocks contain pattern/guard logic
        while (current_block_id < self.cfg.blocks.len) {
            const blk = &self.cfg.blocks[current_block_id];

            // Stop if this looks like body (subject cleanup)
            var starts_body = false;
            var has_cond = false;
            var first_op: ?Opcode = null;
            for (blk.instructions) |inst| {
                if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                if (first_op == null) first_op = inst.opcode;
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                    has_cond = true;
                }
            }
            if (first_op) |op| {
                if (op == .POP_TOP or op == .RETURN_VALUE) {
                    starts_body = !has_cond;
                }
            }
            if (starts_body) break;

            // Check if this block has pattern opcodes or guard-ish ops
            var has_pattern = false;
            var has_guard_ops = false;
            var has_literal_load = false;
            for (blk.instructions) |inst| {
                if (inst.opcode == .LOAD_SMALL_INT or inst.opcode == .LOAD_CONST) {
                    has_literal_load = true;
                }
                if (inst.opcode == .MATCH_SEQUENCE or inst.opcode == .MATCH_MAPPING or
                    inst.opcode == .MATCH_CLASS or inst.opcode == .MATCH_KEYS or
                    inst.opcode == .UNPACK_SEQUENCE or
                    inst.opcode == .STORE_FAST_STORE_FAST or inst.opcode == .STORE_FAST_LOAD_FAST or
                    inst.opcode == .STORE_FAST or inst.opcode == .STORE_NAME or
                    inst.opcode == .POP_JUMP_IF_NONE or inst.opcode == .POP_JUMP_FORWARD_IF_NONE or
                    inst.opcode == .GET_LEN)
                {
                    has_pattern = true;
                }
                if (inst.opcode == .COMPARE_OP and has_literal_load) {
                    has_pattern = true;
                }
                if (inst.opcode == .LOAD_FAST_BORROW or inst.opcode == .LOAD_FAST_BORROW_LOAD_FAST_BORROW or
                    inst.opcode == .LOAD_FAST_LOAD_FAST or inst.opcode == .LOAD_FAST or
                    inst.opcode == .STORE_FAST_LOAD_FAST)
                {
                    has_guard_ops = true;
                }
            }

            var has_cond_term = false;
            if (blk.terminator()) |term| {
                has_cond_term = ctrl.Analyzer.isConditionalJump(undefined, term.opcode);
            }
            has_cond = has_cond or has_cond_term;

            if (!has_pattern and !has_guard_ops and !has_cond) break;

            if (has_pattern) {
                try pattern_blocks.append(self.allocator, current_block_id);
            }
            try test_blocks.append(self.allocator, current_block_id);
            last_test = current_block_id;

            if (blk.terminator()) |term| {
                const next_edge = succEdgeForJump(term.opcode);
                var found_next = false;
                for (blk.successors) |edge| {
                    if (edge.edge_type == next_edge) {
                        current_block_id = edge.target;
                        found_next = true;
                        break;
                    }
                }
                if (!found_next) break;
            } else {
                break;
            }
        }

        // Collect all instructions from pattern blocks for extraction
        var all_insts: std.ArrayList(cfg_mod.Instruction) = .{};
        defer all_insts.deinit(self.allocator);
        for (pattern_blocks.items) |pid| {
            const pb = &self.cfg.blocks[pid];
            try all_insts.appendSlice(self.allocator, pb.instructions);
        }

        // Extract pattern from combined instruction stream
        var pat = if (try self.classPatternFromBlocks(pattern_blocks.items)) |cpat|
            cpat
        else if (try self.mapPatternFromBlocks(pattern_blocks.items)) |mpat|
            mpat
        else
            try self.extractMatchPatternFromInsts(all_insts.items, !has_copy);
        if (isWildcardPattern(pat)) {
            if (try self.literalPatternFromBlock(&self.cfg.blocks[block_id])) |lit_pat| {
                pat = lit_pat;
            }
        }

        var guard: ?*Expr = null;
        const guard_exprs = try self.guardExprsFromBlocks(test_blocks.items);
        if (guard_exprs.len > 0) {
            guard = guard_exprs[0];
            for (guard_exprs[1..]) |g| {
                if (guard) |cur| {
                    if (try self.mergeCompareChain(cur, g)) |merged| {
                        guard = merged;
                        continue;
                    }
                }
                guard = try self.makeBoolPair(guard.?, g, .and_);
            }
        }

        var fallback_body: ?[]const *Stmt = null;
        var fallback_block: ?u32 = null;

        // Find body: if guard exists and body is inline (no separate block), extract from current block
        var body: []const *Stmt = &.{};

        // Use last test block for body/guard edge lookup
        const final_block = &self.cfg.blocks[last_test];

        if (guard != null) {
            var fail_block: ?u32 = null;
            if (final_block.terminator()) |term| {
                const fail_edge = failEdgeForJump(term.opcode);
                for (final_block.successors) |edge| {
                    if (edge.edge_type == fail_edge) {
                        fail_block = edge.target;
                        break;
                    }
                }
            }

            // Guard case: body might be inline after POP_TOP, or in a separate block
            var inline_body = false;
            var seen_jump = false;
            for (final_block.instructions) |inst| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                    seen_jump = true;
                    continue;
                }
                if (!seen_jump) continue;
                if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                if (inst.opcode == .STORE_FAST or inst.opcode == .STORE_NAME or inst.opcode == .STORE_DEREF or
                    inst.opcode == .STORE_FAST_STORE_FAST or inst.opcode == .STORE_FAST_LOAD_FAST)
                {
                    continue;
                }
                if (inst.opcode == .POP_TOP or inst.opcode == .RETURN_VALUE) {
                    inline_body = true;
                    break;
                }
                break;
            }

            // Check if there's a conditional_true edge (separate body block)
            var body_block: ?u32 = null;
            if (!inline_body) {
                for (final_block.successors) |edge| {
                    if (edge.edge_type == .conditional_true) {
                        body_block = edge.target;
                        break;
                    }
                }
                if (body_block == null) {
                    for (final_block.successors) |edge| {
                        if (edge.edge_type == .normal) {
                            body_block = edge.target;
                            break;
                        }
                    }
                }
            }

            if (body_block) |bid| {
                var resolved = bid;
                if (self.jumpTargetIfJumpOnly(bid, true)) |target| {
                    resolved = target;
                }
                if (self.cfg.blocks[resolved].instructions.len == 0) {
                    body_block = null;
                } else {
                    body_block = resolved;
                }
            }

            if (body_block) |bid| {
                // Body in separate block
                var body_end: ?u32 = null;
                const body_blk = &self.cfg.blocks[bid];
                if (self.isSimpleReturnBlock(bid)) {
                    body_end = bid + 1;
                } else if (body_blk.successors.len == 0) {
                    body_end = bid + 1;
                } else {
                    if (final_block.terminator()) |term| {
                        const fail_edge = failEdgeForJump(term.opcode);
                        for (final_block.successors) |edge| {
                            if (edge.edge_type == fail_edge) {
                                body_end = edge.target;
                                break;
                            }
                        }
                    }
                    if (body_end == null) {
                        for (body_blk.successors) |edge| {
                            body_end = edge.target;
                            break;
                        }
                    }
                }

                if (body_end) |end| {
                    if (bid < end) {
                        const pop_need = self.maxLeadPop(bid, end);
                        if (pop_need > 0) {
                            if (pop_need == 1) {
                                var init_stack = [_]StackValue{.unknown};
                                body = try self.decompileStructuredRangeWithStack(bid, end, init_stack[0..]);
                            } else {
                                const init_stack = try self.allocator.alloc(StackValue, pop_need);
                                defer self.allocator.free(init_stack);
                                for (init_stack) |*sv| sv.* = .unknown;
                                body = try self.decompileStructuredRangeWithStack(bid, end, init_stack);
                            }
                        } else {
                            body = try self.decompileStructuredRange(bid, end);
                        }
                    }
                }
            } else {
                // Body inline: find POP_TOP after guard check, decompile rest of block
                var body_start_idx: ?usize = null;
                var fallback_start_idx: ?usize = null;
                var pop_jump_idx: ?usize = null;
                for (final_block.instructions, 0..) |inst, idx| {
                    if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                        pop_jump_idx = idx;
                        break;
                    }
                }

                if (pop_jump_idx) |pj| {
                    const pop_inst = final_block.instructions[pj];
                    if (pop_inst.jumpTarget(self.version)) |fail_off| {
                        var best: ?usize = null;
                        for (final_block.instructions, 0..) |inst, idx| {
                            if (inst.offset >= fail_off) {
                                if (best == null or inst.offset < final_block.instructions[best.?].offset) {
                                    best = idx;
                                }
                            }
                        }
                        fallback_start_idx = best;
                    }

                    var j = pj + 1;
                    while (j < final_block.instructions.len) : (j += 1) {
                        const inst = final_block.instructions[j];
                        if (inst.opcode == .JUMP_FORWARD or inst.opcode == .JUMP_ABSOLUTE) {
                            if (inst.jumpTarget(self.version)) |succ_off| {
                                var best: ?usize = null;
                                for (final_block.instructions, 0..) |iinst, idx| {
                                    if (iinst.offset >= succ_off) {
                                        if (best == null or iinst.offset < final_block.instructions[best.?].offset) {
                                            best = idx;
                                        }
                                    }
                                }
                                body_start_idx = best;
                            }
                            break;
                        }
                        if (fallback_start_idx) |fb| {
                            if (j >= fb) break;
                        }
                    }
                }

                if (body_start_idx == null) {
                    var found_jump = false;
                    for (final_block.instructions, 0..) |inst, idx| {
                        if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                            found_jump = true;
                            continue;
                        }
                        if (!found_jump) continue;
                        if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                        if (inst.opcode == .STORE_FAST or inst.opcode == .STORE_NAME or inst.opcode == .STORE_DEREF or
                            inst.opcode == .STORE_FAST_STORE_FAST or inst.opcode == .STORE_FAST_LOAD_FAST)
                        {
                            continue;
                        }
                        if (inst.opcode == .POP_TOP) {
                            body_start_idx = idx + 1; // Start after POP_TOP
                            break;
                        }
                        body_start_idx = idx; // Start at first non-POP_TOP after jump
                        break;
                    }
                }
                if (body_start_idx == null) {
                    if (fallback_start_idx) |fb| {
                        var k = fb;
                        while (k < final_block.instructions.len) : (k += 1) {
                            if (final_block.instructions[k].opcode == .RETURN_VALUE) {
                                k += 1;
                                while (k < final_block.instructions.len) : (k += 1) {
                                    const op = final_block.instructions[k].opcode;
                                    if (op == .NOT_TAKEN or op == .CACHE or op == .POP_TOP) continue;
                                    body_start_idx = k;
                                    break;
                                }
                                break;
                            }
                        }
                    }
                }

                if (body_start_idx) |start_idx| {
                    // Create a temporary block with just the body instructions
                    var body_insts: std.ArrayList(cfg_mod.Instruction) = .{};
                    defer body_insts.deinit(self.allocator);
                    try body_insts.appendSlice(self.allocator, final_block.instructions[start_idx..]);

                    const a = self.arena.allocator();
                    var stmts: std.ArrayList(*Stmt) = .{};
                    defer stmts.deinit(a);

                    var sim = self.initSim(a, a, self.code, self.version);
                    defer sim.deinit();

                    for (body_insts.items) |inst| {
                        if (inst.opcode == .RETURN_VALUE) {
                            const val = if (sim.stack.popExpr()) |expr| expr else |err| switch (err) {
                                error.StackUnderflow => blk: {
                                    const none_expr = try a.create(Expr);
                                    none_expr.* = .{ .constant = .{ .none = {} } };
                                    break :blk none_expr;
                                },
                                else => return err,
                            };
                            const stmt = try a.create(Stmt);
                            stmt.* = .{ .return_stmt = .{ .value = val } };
                            try stmts.append(a, stmt);
                            break;
                        } else {
                            try sim.simulate(inst);
                        }
                    }

                    body = try stmts.toOwnedSlice(a);
                }

                if (fallback_body == null) {
                    if (fallback_start_idx) |fb_start| {
                        var fb_insts: std.ArrayList(cfg_mod.Instruction) = .{};
                        defer fb_insts.deinit(self.allocator);
                        try fb_insts.appendSlice(self.allocator, final_block.instructions[fb_start..]);

                        const a = self.arena.allocator();
                        var stmts: std.ArrayList(*Stmt) = .{};
                        defer stmts.deinit(a);

                        var sim = self.initSim(a, a, self.code, self.version);
                        defer sim.deinit();

                        for (fb_insts.items) |inst| {
                            if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE or inst.opcode == .POP_TOP) continue;
                            if (inst.opcode == .RETURN_VALUE) {
                                const val = if (sim.stack.popExpr()) |expr| expr else |err| switch (err) {
                                    error.StackUnderflow => blk: {
                                        const none_expr = try a.create(Expr);
                                        none_expr.* = .{ .constant = .{ .none = {} } };
                                        break :blk none_expr;
                                    },
                                    else => return err,
                                };
                                const stmt = try a.create(Stmt);
                                stmt.* = .{ .return_stmt = .{ .value = val } };
                                try stmts.append(a, stmt);
                                break;
                            } else {
                                try sim.simulate(inst);
                            }
                        }

                        if (stmts.items.len > 0) {
                            fallback_body = try stmts.toOwnedSlice(a);
                        }
                    }
                }
            }

            if (fallback_block == null) {
                fallback_block = fail_block;
            }
            if (fallback_body == null) {
                if (fallback_block) |fb| {
                    if (self.isSimpleReturnBlock(fb)) {
                        var fb_end: u32 = fb + 1;
                        const fblk = &self.cfg.blocks[fb];
                        if (fblk.successors.len > 0) {
                            fb_end = fblk.successors[0].target;
                        }
                        if (fb < fb_end) {
                            const pop_need = self.maxLeadPop(fb, fb_end);
                            if (pop_need > 0) {
                                if (pop_need == 1) {
                                    var init_stack = [_]StackValue{.unknown};
                                    fallback_body = try self.decompileStructuredRangeWithStack(fb, fb_end, init_stack[0..]);
                                } else {
                                    const init_stack = try self.allocator.alloc(StackValue, pop_need);
                                    defer self.allocator.free(init_stack);
                                    for (init_stack) |*sv| sv.* = .unknown;
                                    fallback_body = try self.decompileStructuredRangeWithStack(fb, fb_end, init_stack);
                                }
                            } else {
                                fallback_body = try self.decompileStructuredRange(fb, fb_end);
                            }
                        }
                    }
                }
            }
        } else {
            // No guard: body in true branch or inline
            var inline_body = false;
            var seen_jump = false;
            for (final_block.instructions) |inst| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                    seen_jump = true;
                    continue;
                }
                if (!seen_jump) continue;
                if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                if (inst.opcode == .STORE_FAST or inst.opcode == .STORE_NAME or inst.opcode == .STORE_DEREF or
                    inst.opcode == .STORE_FAST_STORE_FAST or inst.opcode == .STORE_FAST_LOAD_FAST)
                {
                    continue;
                }
                if (inst.opcode == .POP_TOP or inst.opcode == .RETURN_VALUE) {
                    inline_body = true;
                    break;
                }
                break;
            }

            var body_block: ?u32 = null;
            if (!inline_body) {
                for (final_block.successors) |edge| {
                    if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                        body_block = edge.target;
                        break;
                    }
                }
            }

            if (body_block) |bid| {
                if (self.cfg.blocks[bid].instructions.len == 0) {
                    body_block = null;
                }
            }

            if (body_block) |bid| {
                var body_end: u32 = last_test + 1;
                const body_blk = &self.cfg.blocks[bid];
                if (body_blk.successors.len == 0) {
                    body_end = bid + 1;
                } else if (final_block.terminator()) |term| {
                    const fail_edge = failEdgeForJump(term.opcode);
                    for (final_block.successors) |edge| {
                        if (edge.edge_type == fail_edge) {
                            body_end = edge.target;
                            break;
                        }
                    }
                }
                if (bid < body_end) {
                    const pop_need = self.maxLeadPop(bid, body_end);
                    if (pop_need > 0) {
                        if (pop_need == 1) {
                            var init_stack = [_]StackValue{.unknown};
                            body = try self.decompileStructuredRangeWithStack(bid, body_end, init_stack[0..]);
                        } else {
                            const init_stack = try self.allocator.alloc(StackValue, pop_need);
                            defer self.allocator.free(init_stack);
                            for (init_stack) |*sv| sv.* = .unknown;
                            body = try self.decompileStructuredRangeWithStack(bid, body_end, init_stack);
                        }
                    } else {
                        body = try self.decompileStructuredRange(bid, body_end);
                    }
                }
            } else {
                // Body inline: find POP_TOP after guard check or NOP (fallback)
                var start_idx: ?usize = null;
                var fallback_start_idx: ?usize = null;
                var jump_idx: ?usize = null;
                var found_jump = false;
                for (final_block.instructions, 0..) |inst, idx| {
                    if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                        if (jump_idx == null) jump_idx = idx;
                        found_jump = true;
                        continue;
                    }
                    if (!found_jump) continue;
                    if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                    if (inst.opcode == .STORE_FAST or inst.opcode == .STORE_NAME or inst.opcode == .STORE_DEREF or
                        inst.opcode == .STORE_FAST_STORE_FAST or inst.opcode == .STORE_FAST_LOAD_FAST)
                    {
                        continue;
                    }
                    if (inst.opcode == .POP_TOP) {
                        start_idx = idx + 1;
                        break;
                    }
                    if (inst.opcode == .NOP) {
                        start_idx = idx + 1;
                        break;
                    }
                }
                if (jump_idx) |pj| {
                    const jinst = final_block.instructions[pj];
                    if (jinst.jumpTarget(self.version)) |fail_off| {
                        var best: ?usize = null;
                        for (final_block.instructions, 0..) |inst, idx| {
                            if (inst.offset >= fail_off) {
                                if (best == null or inst.offset < final_block.instructions[best.?].offset) {
                                    best = idx;
                                }
                            }
                        }
                        fallback_start_idx = best;
                    }
                }
                if (start_idx == null and !found_jump) {
                    for (final_block.instructions, 0..) |inst, idx| {
                        if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
                        if (inst.opcode == .NOP) {
                            start_idx = idx + 1;
                            break;
                        }
                        start_idx = idx;
                        break;
                    }
                }

                if (start_idx) |start| {
                    const aa = self.arena.allocator();
                    var stmts: std.ArrayList(*Stmt) = .{};
                    defer stmts.deinit(aa);
                    var sim = self.initSim(aa, aa, self.code, self.version);
                    defer sim.deinit();

                    for (final_block.instructions[start..]) |inst| {
                        if (inst.opcode == .RETURN_VALUE) {
                            const val = if (sim.stack.popExpr()) |expr| expr else |err| switch (err) {
                                error.StackUnderflow => blk: {
                                    const none_expr = try aa.create(Expr);
                                    none_expr.* = .{ .constant = .{ .none = {} } };
                                    break :blk none_expr;
                                },
                                else => return err,
                            };
                            const stmt = try aa.create(Stmt);
                            stmt.* = .{ .return_stmt = .{ .value = val } };
                            try stmts.append(aa, stmt);
                            break;
                        } else {
                            try sim.simulate(inst);
                        }
                    }

                    body = try stmts.toOwnedSlice(aa);
                }
                if (fallback_body == null) {
                    if (fallback_start_idx) |fb_start| {
                        var fb_insts: std.ArrayList(cfg_mod.Instruction) = .{};
                        defer fb_insts.deinit(self.allocator);
                        try fb_insts.appendSlice(self.allocator, final_block.instructions[fb_start..]);

                        const aa = self.arena.allocator();
                        var stmts: std.ArrayList(*Stmt) = .{};
                        defer stmts.deinit(aa);
                        var sim = self.initSim(aa, aa, self.code, self.version);
                        defer sim.deinit();

                        for (fb_insts.items) |inst| {
                            if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE or inst.opcode == .POP_TOP) continue;
                            if (inst.opcode == .RETURN_VALUE) {
                                const val = if (sim.stack.popExpr()) |expr| expr else |err| switch (err) {
                                    error.StackUnderflow => blk: {
                                        const none_expr = try aa.create(Expr);
                                        none_expr.* = .{ .constant = .{ .none = {} } };
                                        break :blk none_expr;
                                    },
                                    else => return err,
                                };
                                const stmt = try aa.create(Stmt);
                                stmt.* = .{ .return_stmt = .{ .value = val } };
                                try stmts.append(aa, stmt);
                                break;
                            } else {
                                try sim.simulate(inst);
                            }
                        }

                        if (stmts.items.len > 0) {
                            fallback_body = try stmts.toOwnedSlice(aa);
                        }
                    }
                }
            }
            if (fallback_block == null) {
                if (final_block.terminator()) |term| {
                    const fail_edge = failEdgeForJump(term.opcode);
                    for (final_block.successors) |edge| {
                        if (edge.edge_type == fail_edge) {
                            fallback_block = edge.target;
                            break;
                        }
                    }
                }
            }
            if (fallback_body == null) {
                if (fallback_block) |fb| {
                    if (self.isSimpleReturnBlock(fb)) {
                        var fb_end: u32 = fb + 1;
                        const fblk = &self.cfg.blocks[fb];
                        if (fblk.successors.len > 0) {
                            fb_end = fblk.successors[0].target;
                        }
                        if (fb < fb_end) {
                            const pop_need = self.maxLeadPop(fb, fb_end);
                            if (pop_need > 0) {
                                if (pop_need == 1) {
                                    var init_stack = [_]StackValue{.unknown};
                                    fallback_body = try self.decompileStructuredRangeWithStack(fb, fb_end, init_stack[0..]);
                                } else {
                                    const init_stack = try self.allocator.alloc(StackValue, pop_need);
                                    defer self.allocator.free(init_stack);
                                    for (init_stack) |*sv| sv.* = .unknown;
                                    fallback_body = try self.decompileStructuredRangeWithStack(fb, fb_end, init_stack);
                                }
                            } else {
                                fallback_body = try self.decompileStructuredRange(fb, fb_end);
                            }
                        }
                    }
                }
            }
        }

        return MatchCaseResult{
            .case = .{
                .pattern = pat,
                .guard = guard,
                .body = body,
            },
            .fallback_body = fallback_body,
            .fallback_block = fallback_block,
        };
    }

    pub fn extractMatchPatternFromInsts(self: *Decompiler, insts: []const cfg_mod.Instruction, subject_on_stack: bool) DecompileError!*ast.Pattern {
        const a = self.arena.allocator();
        var sim = self.initSim(a, a, self.code, self.version);
        defer sim.deinit();

        var subject_expr: ?*Expr = null;
        if (subject_on_stack) {
            const placeholder = try a.create(Expr);
            placeholder.* = .{ .name = .{ .id = "<subject>", .ctx = .load } };
            try sim.stack.push(.{ .expr = placeholder });
            subject_expr = placeholder;
        }

        var has_match_seq = false;
        var has_match_map = false;
        var literal_val: ?*Expr = null;
        var map_keys: ?[]const *Expr = null;
        var class_info: ?ClassInfo = null;
        var last_cls: ?*Expr = null;
        var last_attrs: ?[]const []const u8 = null;
        var seq_stack: std.ArrayListUnmanaged(SeqBuild) = .{};
        defer {
            for (seq_stack.items) |*sb| {
                sb.items.deinit(self.allocator);
            }
            seq_stack.deinit(self.allocator);
        }

        // Pre-scan for mapping keys so UNPACK_SEQUENCE can use them
        var scan_idx: usize = 0;
        while (scan_idx < insts.len) : (scan_idx += 1) {
            if (insts[scan_idx].opcode != .MATCH_KEYS) continue;
            var j = scan_idx;
            while (j > 0) {
                j -= 1;
                const op = insts[j].opcode;
                if (op == .NOT_TAKEN or op == .CACHE) continue;
                if (op == .LOAD_CONST) {
                    const obj = self.code.consts[insts[j].arg];
                    map_keys = try self.keyExprsFromObj(obj);
                    break;
                }
                if (op == .MATCH_MAPPING) break;
            }
            break;
        }

        var prev_was_load = false;
        var unpack_count: ?u32 = null;
        var first_unpack: ?usize = null;
        var prev_was_get_len = false;
        var unpack_ex_before: usize = 0;
        var unpack_ex_after: usize = 0;
        var unpack_ex_seen: usize = 0;
        var unpack_ex_active = false;
        for (insts, 0..) |inst, idx| {
            switch (inst.opcode) {
                .MATCH_SEQUENCE => has_match_seq = true,
                .MATCH_MAPPING => has_match_map = true,
                .COPY => {
                    if (sim.stack.len() == 0) {
                        const placeholder = try a.create(Expr);
                        placeholder.* = .{ .name = .{ .id = "<subject>", .ctx = .load } };
                        try sim.stack.push(.{ .expr = placeholder });
                        if (subject_expr == null) subject_expr = placeholder;
                    } else if (subject_expr == null) {
                        const items = sim.stack.items.items;
                        switch (items[items.len - 1]) {
                            .expr => |e| subject_expr = e,
                            else => {},
                        }
                    }
                },
                .MATCH_KEYS => {
                    if (map_keys == null) {
                        var j = idx;
                        while (j > 0) {
                            j -= 1;
                            const op = insts[j].opcode;
                            if (op == .NOT_TAKEN or op == .CACHE) continue;
                            if (op == .LOAD_CONST) {
                                const obj = self.code.consts[insts[j].arg];
                                map_keys = try self.keyExprsFromObj(obj);
                                break;
                            }
                            if (op == .MATCH_MAPPING) break;
                        }
                    }
                    try sim.simulate(inst);
                },
                .MATCH_CLASS => {
                    if (last_cls != null and last_attrs != null) {
                        class_info = .{ .cls = last_cls.?, .attrs = last_attrs.? };
                    }
                    last_attrs = null;
                    try sim.simulate(inst);
                },
                .GET_LEN => {
                    prev_was_get_len = true;
                    try sim.simulate(inst);
                },
                .LOAD_NAME => {
                    prev_was_load = true;
                    prev_was_get_len = false;
                    const name = self.code.names[inst.arg];
                    last_cls = try self.makeName(name, .load);
                    try sim.simulate(inst);
                    if (subject_expr == null) {
                        const items = sim.stack.items.items;
                        if (items.len > 0) {
                            switch (items[items.len - 1]) {
                                .expr => |e| subject_expr = e,
                                else => {},
                            }
                        }
                    }
                },
                .LOAD_FAST => {
                    prev_was_load = true;
                    prev_was_get_len = false;
                    try sim.simulate(inst);
                    if (subject_expr == null) {
                        const items = sim.stack.items.items;
                        if (items.len > 0) {
                            switch (items[items.len - 1]) {
                                .expr => |e| subject_expr = e,
                                else => {},
                            }
                        }
                    }
                },
                .LOAD_GLOBAL => {
                    prev_was_load = false;
                    prev_was_get_len = false;
                    const name = self.code.names[inst.arg];
                    last_cls = try self.makeName(name, .load);
                    try sim.simulate(inst);
                    if (subject_expr == null) {
                        const items = sim.stack.items.items;
                        if (items.len > 0) {
                            switch (items[items.len - 1]) {
                                .expr => |e| subject_expr = e,
                                else => {},
                            }
                        }
                    }
                },
                .LOAD_CONST, .LOAD_SMALL_INT => {
                    prev_was_load = false;
                    // Look ahead: only treat as literal when directly compared
                    const next_op = nextOp(insts, idx);
                    if (inst.opcode == .LOAD_CONST and next_op == .MATCH_KEYS) {
                        const obj = self.code.consts[inst.arg];
                        map_keys = try self.keyExprsFromObj(obj);
                        try sim.simulate(inst);
                        break;
                    }
                    if (inst.opcode == .LOAD_CONST and next_op == .MATCH_CLASS) {
                        const obj = self.code.consts[inst.arg];
                        last_attrs = try self.attrNamesFromObj(obj);
                        try sim.simulate(inst);
                        break;
                    }
                    if (!prev_was_get_len and next_op == .COMPARE_OP) {
                        try sim.simulate(inst);
                        const lit = try sim.stack.popExpr();
                        if (seq_stack.items.len > 0) {
                            literal_val = lit;
                        } else {
                            var is_subject = false;
                            const items = sim.stack.items.items;
                            if (items.len >= 2) {
                                switch (items[items.len - 2]) {
                                    .expr => |e| {
                                        if (subject_expr == null or e == subject_expr.?) is_subject = true;
                                    },
                                    else => {},
                                }
                            }
                            if (is_subject) {
                                literal_val = lit;
                            } else {
                                literal_val = null;
                            }
                        }
                    } else {
                        try sim.simulate(inst);
                    }
                },
                .COMPARE_OP => {
                    prev_was_load = false;
                    // Literal match - use the constant (only if we have one and not in length check)
                    if (!prev_was_get_len and literal_val != null) {
                        if (seq_stack.items.len > 0) {
                            const pat = try self.arena.allocator().create(ast.Pattern);
                            pat.* = .{ .match_value = literal_val.? };
                            var top = &seq_stack.items[seq_stack.items.len - 1];
                            try top.items.append(self.allocator, pat);
                            literal_val = null;
                            if (try self.finishSeq(&seq_stack)) |seq_pat| return seq_pat;
                        } else {
                            const pat = try self.arena.allocator().create(ast.Pattern);
                            pat.* = .{ .match_value = literal_val.? };
                            return pat;
                        }
                    }
                    prev_was_get_len = false;
                    // Skip simulation of comparison - it produces bool which breaks subsequent pattern logic
                },
                .UNPACK_SEQUENCE => {
                    unpack_count = inst.arg;
                    if (first_unpack == null) first_unpack = idx;
                    if (map_keys) |keys| {
                        if (keys.len == @as(usize, inst.arg)) {
                            const pats = try a.alloc(*ast.Pattern, keys.len);
                            var filled: usize = 0;
                            var j = idx + 1;
                            while (j < insts.len and filled < keys.len) : (j += 1) {
                                const op = insts[j].opcode;
                                if (op == .NOT_TAKEN or op == .CACHE or op == .POP_TOP) continue;
                                if (op == .STORE_FAST or op == .STORE_NAME) {
                                    const name = if (op == .STORE_NAME)
                                        self.code.names[insts[j].arg]
                                    else
                                        self.code.varnames[insts[j].arg];
                                    const unmangled = try self.unmangleClassName(name);
                                    const p = try a.create(ast.Pattern);
                                    p.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                                    pats[filled] = p;
                                    filled += 1;
                                    continue;
                                }
                                if (op == .LOAD_SMALL_INT or op == .LOAD_CONST) {
                                    const next_op = nextOp(insts, j);
                                    if (next_op == .COMPARE_OP) {
                                        const val_expr = if (op == .LOAD_SMALL_INT)
                                            try ast.makeConstant(a, .{ .int = @intCast(insts[j].arg) })
                                        else
                                            try self.constExprFromObj(self.code.consts[insts[j].arg]);
                                        const p = try a.create(ast.Pattern);
                                        p.* = .{ .match_value = val_expr };
                                        pats[filled] = p;
                                        filled += 1;
                                        continue;
                                    }
                                }
                                break;
                            }
                            if (filled == keys.len) {
                                const pat = try a.create(ast.Pattern);
                                pat.* = .{ .match_mapping = .{ .keys = keys, .patterns = pats, .rest = null } };
                                return pat;
                            }
                        }
                    }
                    if (map_keys == null and class_info == null) {
                        try seq_stack.append(self.allocator, .{ .expected = @intCast(inst.arg) });
                    }
                    try sim.simulate(inst);
                },
                .UNPACK_EX => {
                    const before = @as(usize, inst.arg & 0xFF);
                    const after = @as(usize, inst.arg >> 8);
                    unpack_ex_before = before;
                    unpack_ex_after = after;
                    unpack_ex_seen = 0;
                    unpack_ex_active = true;
                    if (map_keys == null and class_info == null) {
                        try seq_stack.append(self.allocator, .{ .expected = before + after + 1 });
                    }
                },
                .SWAP => {
                    if (seq_stack.items.len > 0 and inst.arg == 2) {
                        var top = &seq_stack.items[seq_stack.items.len - 1];
                        if (top.expected == 2 and top.items.items.len == 0) {
                            top.swap = true;
                            continue;
                        }
                    }
                    try sim.simulate(inst);
                },
                .STORE_FAST_STORE_FAST => {
                    // Python 3.14+: UNPACK_SEQUENCE followed by STORE_FAST_STORE_FAST
                    // Build match_sequence pattern with bindings
                    if (seq_stack.items.len > 0) {
                        const idx1 = (inst.arg >> 4) & 0xF;
                        const idx2 = inst.arg & 0xF;
                        const name1 = self.code.varnames[idx1];
                        const name2 = self.code.varnames[idx2];
                        const unmangled1 = try self.unmangleClassName(name1);
                        const unmangled2 = try self.unmangleClassName(name2);
                        const pat1 = try a.create(ast.Pattern);
                        const pat2 = try a.create(ast.Pattern);
                        if (unpack_ex_active and unpack_ex_seen == unpack_ex_before) {
                            pat1.* = .{ .match_star = unmangled1 };
                        } else {
                            pat1.* = .{ .match_as = .{ .pattern = null, .name = unmangled1 } };
                        }
                        unpack_ex_seen += 1;
                        if (unpack_ex_active and unpack_ex_seen == unpack_ex_before) {
                            pat2.* = .{ .match_star = unmangled2 };
                        } else {
                            pat2.* = .{ .match_as = .{ .pattern = null, .name = unmangled2 } };
                        }
                        unpack_ex_seen += 1;
                        if (unpack_ex_active and unpack_ex_seen >= unpack_ex_before + unpack_ex_after + 1) {
                            unpack_ex_active = false;
                        }
                        var top = &seq_stack.items[seq_stack.items.len - 1];
                        try top.items.append(self.allocator, pat1);
                        try top.items.append(self.allocator, pat2);
                        if (try self.finishSeq(&seq_stack)) |seq_pat| {
                            if (self.findAsName(insts, idx)) |as_name| {
                                const as_pat = try a.create(ast.Pattern);
                                const unmangled_as = try self.unmangleClassName(as_name);
                                as_pat.* = .{ .match_as = .{ .pattern = seq_pat, .name = unmangled_as } };
                                return as_pat;
                            }
                            return seq_pat;
                        }
                        continue;
                    }
                    if (unpack_count) |count| {
                        if (count == 2) {
                            // arg packs indices: hi=first var, lo=second var
                            const idx1 = (inst.arg >> 4) & 0xF;
                            const idx2 = inst.arg & 0xF;
                            const name1 = self.code.varnames[idx1];
                            const name2 = self.code.varnames[idx2];
                            const unmangled1 = try self.unmangleClassName(name1);
                            const unmangled2 = try self.unmangleClassName(name2);

                            const pat1 = try a.create(ast.Pattern);
                            pat1.* = .{ .match_as = .{ .pattern = null, .name = unmangled1 } };
                            const pat2 = try a.create(ast.Pattern);
                            pat2.* = .{ .match_as = .{ .pattern = null, .name = unmangled2 } };

                            if (class_info) |ci| {
                                const pats = try a.alloc(*ast.Pattern, 2);
                                pats[0] = pat1;
                                pats[1] = pat2;
                                const pat = try a.create(ast.Pattern);
                                pat.* = .{ .match_class = .{
                                    .cls = ci.cls,
                                    .patterns = &.{},
                                    .kwd_attrs = ci.attrs,
                                    .kwd_patterns = pats,
                                } };
                                return pat;
                            }

                            if (seq_stack.items.len > 0) {
                                var top = &seq_stack.items[seq_stack.items.len - 1];
                                try top.items.append(self.allocator, pat1);
                                try top.items.append(self.allocator, pat2);
                                if (try self.finishSeq(&seq_stack)) |seq_pat| {
                                    if (self.findAsName(insts, idx)) |as_name| {
                                        const as_pat = try a.create(ast.Pattern);
                                        const unmangled_as = try self.unmangleClassName(as_name);
                                        as_pat.* = .{ .match_as = .{ .pattern = seq_pat, .name = unmangled_as } };
                                        return as_pat;
                                    }
                                    return seq_pat;
                                }
                            } else {
                                const pats = try a.alloc(*ast.Pattern, 2);
                                pats[0] = pat1;
                                pats[1] = pat2;
                                const pat = try a.create(ast.Pattern);
                                pat.* = .{ .match_sequence = pats };
                                if (self.findAsName(insts, idx)) |as_name| {
                                    const as_pat = try a.create(ast.Pattern);
                                    const unmangled_as = try self.unmangleClassName(as_name);
                                    as_pat.* = .{ .match_as = .{ .pattern = pat, .name = unmangled_as } };
                                    return as_pat;
                                }
                                return pat;
                            }
                        }
                    }
                    // Don't simulate - this would pop from empty stack
                },
                .STORE_FAST_LOAD_FAST => {
                    // Python 3.14+: combined store+load for pattern binding
                    if (seq_stack.items.len > 0) {
                        const load_idx = inst.arg & 0xF;
                        const name = self.code.varnames[load_idx];
                        const unmangled = try self.unmangleClassName(name);
                        const pat = try a.create(ast.Pattern);
                        pat.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                        var top = &seq_stack.items[seq_stack.items.len - 1];
                        try top.items.append(self.allocator, pat);
                        if (try self.finishSeq(&seq_stack)) |seq_pat| return seq_pat;
                        continue;
                    }
                    if (unpack_count) |count| {
                        if (count == 1) {
                            const load_idx = inst.arg & 0xF;
                            const name = self.code.varnames[load_idx];
                            const unmangled = try self.unmangleClassName(name);
                            const pat1 = try a.create(ast.Pattern);
                            pat1.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };

                            const pats = try a.alloc(*ast.Pattern, 1);
                            pats[0] = pat1;

                            const pat = try a.create(ast.Pattern);
                            pat.* = .{ .match_sequence = pats };
                            return pat;
                        }
                    } else {
                        const load_idx = inst.arg & 0xF;
                        const name = self.code.varnames[load_idx];
                        const unmangled = try self.unmangleClassName(name);
                        const pat = try a.create(ast.Pattern);
                        pat.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                        return pat;
                    }
                },
                .STORE_NAME, .STORE_FAST => {
                    if (seq_stack.items.len > 0) {
                        const name = if (inst.opcode == .STORE_NAME)
                            self.code.names[inst.arg]
                        else
                            self.code.varnames[inst.arg];
                        const unmangled = try self.unmangleClassName(name);
                        const pat = try a.create(ast.Pattern);
                        if (unpack_ex_active and unpack_ex_seen == unpack_ex_before) {
                            pat.* = .{ .match_star = unmangled };
                        } else {
                            pat.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                        }
                        var top = &seq_stack.items[seq_stack.items.len - 1];
                        try top.items.append(self.allocator, pat);
                        unpack_ex_seen += 1;
                        if (unpack_ex_active and unpack_ex_seen >= unpack_ex_before + unpack_ex_after + 1) {
                            unpack_ex_active = false;
                        }
                        if (try self.finishSeq(&seq_stack)) |seq_pat| return seq_pat;
                        continue;
                    }
                    // Capture pattern only if previous was LOAD (subject load → pattern binding)
                    if (prev_was_load) {
                        const name = if (inst.opcode == .STORE_NAME)
                            self.code.names[inst.arg]
                        else
                            self.code.varnames[inst.arg];
                        const unmangled = try self.unmangleClassName(name);

                        const pat = try self.arena.allocator().create(ast.Pattern);
                        pat.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                        return pat;
                    }
                    prev_was_load = false;
                    try sim.simulate(inst);
                },
                .NOP => {
                    prev_was_load = false;
                    // Wildcard pattern
                    const pat = try self.arena.allocator().create(ast.Pattern);
                    pat.* = .{ .match_as = .{ .pattern = null, .name = null } };
                    return pat;
                },
                .POP_JUMP_IF_FALSE, .POP_JUMP_FORWARD_IF_FALSE, .POP_JUMP_IF_TRUE, .TO_BOOL => {
                    // Skip - these are control flow, not pattern
                    prev_was_load = false;
                },
                else => {
                    prev_was_load = false;
                    try sim.simulate(inst);
                },
            }
        }

        if (map_keys) |keys| {
            if (first_unpack) |u_idx| {
                if (keys.len > 0) {
                    const pats = try a.alloc(*ast.Pattern, keys.len);
                    var filled: usize = 0;
                    var j = u_idx + 1;
                    while (j < insts.len and filled < keys.len) : (j += 1) {
                        const op = insts[j].opcode;
                        if (op == .NOT_TAKEN or op == .CACHE or op == .POP_TOP) continue;
                        if (op == .STORE_FAST or op == .STORE_NAME) {
                            const name = if (op == .STORE_NAME)
                                self.code.names[insts[j].arg]
                            else
                                self.code.varnames[insts[j].arg];
                            const unmangled = try self.unmangleClassName(name);
                            const p = try a.create(ast.Pattern);
                            p.* = .{ .match_as = .{ .pattern = null, .name = unmangled } };
                            pats[filled] = p;
                            filled += 1;
                            continue;
                        }
                        if (op == .LOAD_SMALL_INT or op == .LOAD_CONST) {
                            const next_op = nextOp(insts, j);
                            if (next_op == .COMPARE_OP) {
                                const val_expr = if (op == .LOAD_SMALL_INT)
                                    try ast.makeConstant(a, .{ .int = @intCast(insts[j].arg) })
                                else
                                    try self.constExprFromObj(self.code.consts[insts[j].arg]);
                                const p = try a.create(ast.Pattern);
                                p.* = .{ .match_value = val_expr };
                                pats[filled] = p;
                                filled += 1;
                                continue;
                            }
                        }
                        break;
                    }
                    if (filled == keys.len) {
                        const pat = try a.create(ast.Pattern);
                        pat.* = .{ .match_mapping = .{ .keys = keys, .patterns = pats, .rest = null } };
                        return pat;
                    }
                }
            }
        }

        if (seq_stack.items.len > 0) {
            if (try self.finishSeq(&seq_stack)) |seq_pat| return seq_pat;
        }

        // Default to wildcard if we can't determine pattern
        const pat = try self.arena.allocator().create(ast.Pattern);
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
        return self.decompileStructuredRangeWithStackInner(start, end, &.{}, false, false);
    }

    fn decompileStructuredRangeNoTry(self: *Decompiler, start: u32, end: u32) DecompileError![]const *Stmt {
        return self.decompileStructuredRangeWithStackInner(start, end, &.{}, true, false);
    }

    fn decompileStructuredRangeWithStack(self: *Decompiler, start: u32, end: u32, init_stack: []const StackValue) DecompileError![]const *Stmt {
        return self.decompileStructuredRangeWithStackInner(start, end, init_stack, false, false);
    }

    fn decompileStructuredRangeNoTryWithStack(self: *Decompiler, start: u32, end: u32, init_stack: []const StackValue) DecompileError![]const *Stmt {
        return self.decompileStructuredRangeWithStackInner(start, end, init_stack, true, false);
    }

    fn decompileStructuredRangeWithStackAllowHandlers(self: *Decompiler, start: u32, end: u32, init_stack: []const StackValue) DecompileError![]const *Stmt {
        return self.decompileStructuredRangeWithStackInner(start, end, init_stack, false, true);
    }

    fn decompileStructuredRangeNoTryWithStackAllowHandlers(self: *Decompiler, start: u32, end: u32, init_stack: []const StackValue) DecompileError![]const *Stmt {
        return self.decompileStructuredRangeWithStackInner(start, end, init_stack, true, true);
    }

    fn decompileStructuredRangeWithStackInner(
        self: *Decompiler,
        start: u32,
        end: u32,
        init_stack: []const StackValue,
        skip_try: bool,
        allow_handlers: bool,
    ) DecompileError![]const *Stmt {
        // Handle empty range (start == end)
        if (start >= end) return &[_]*Stmt{};
        const range_key: u64 = (@as(u64, start) << 32) | @as(u64, end);
        if (self.range_in_progress.contains(range_key)) return &[_]*Stmt{};
        try self.range_in_progress.put(range_key, {});
        defer _ = self.range_in_progress.remove(range_key);

        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

        var block_idx = start;
        const limit = @min(end, @as(u32, @intCast(self.cfg.blocks.len)));

        while (block_idx < limit) {
            const prev_idx = block_idx;
            const stmts_len = stmts.items.len;
            if (self.consumed.isSet(block_idx)) {
                block_idx += 1;
                continue;
            }
            if (block_idx != start and self.cfg.blocks[block_idx].predecessors.len == 0) {
                block_idx += 1;
                continue;
            }
            if (!allow_handlers and self.cfg.blocks[block_idx].is_exception_handler) {
                block_idx += 1;
                continue;
            }
            if (try self.tryDecompileBoolOpInto(block_idx, limit, &stmts, a)) |next_block| {
                block_idx = next_block;
                if (block_idx <= prev_idx) {
                    if (self.last_error_ctx == null) {
                        self.last_error_ctx = .{
                            .code_name = self.code.name,
                            .block_id = prev_idx,
                            .offset = self.cfg.blocks[prev_idx].start_offset,
                            .opcode = "boolop_no_progress",
                        };
                    }
                    return error.InvalidBlock;
                }
                continue;
            }
            if (try self.tryDecompileTernaryInto(block_idx, limit, &stmts, a)) |next_block| {
                block_idx = next_block;
                if (block_idx <= prev_idx) {
                    if (self.last_error_ctx == null) {
                        self.last_error_ctx = .{
                            .code_name = self.code.name,
                            .block_id = prev_idx,
                            .offset = self.cfg.blocks[prev_idx].start_offset,
                            .opcode = "ternary_no_progress",
                        };
                    }
                    return error.InvalidBlock;
                }
                continue;
            }
            const pattern = if (skip_try)
                try self.analyzer.detectPatternNoTry(block_idx)
            else
                try self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    const cond_block = &self.cfg.blocks[p.condition_block];
                    var last_stmt_idx: ?usize = null;
                    for (cond_block.instructions, 0..) |inst, idx| {
                        if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                        if (inst.opcode == .JUMP_BACKWARD or inst.opcode == .JUMP_BACKWARD_NO_INTERRUPT) break;
                        switch (inst.opcode) {
                            .STORE_FAST,
                            .STORE_NAME,
                            .STORE_GLOBAL,
                            .STORE_DEREF,
                            .STORE_ATTR,
                            .STORE_SUBSCR,
                            .POP_TOP,
                            .DELETE_NAME,
                            .DELETE_FAST,
                            .DELETE_GLOBAL,
                            .DELETE_DEREF,
                            .DELETE_ATTR,
                            .DELETE_SUBSCR,
                            .RETURN_VALUE,
                            .RETURN_CONST,
                            .RAISE_VARARGS,
                            => last_stmt_idx = idx + 1,
                            else => {},
                        }
                    }

                    const skip_cond = last_stmt_idx orelse 0;
                    if (skip_cond > 0) {
                        var skip_first_store = false;
                        try self.processPartialBlock(cond_block, &stmts, a, &skip_first_store, skip_cond);
                    }

                    const stmt = if (skip_cond > 0)
                        try self.decompileIfWithSkip(p, skip_cond)
                    else
                        try self.decompileIf(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    if (self.if_next) |next| {
                        block_idx = next;
                        self.if_next = null;
                        self.chained_cmp_next_block = null;
                    } else if (self.chained_cmp_next_block) |chain_next| {
                        block_idx = chain_next;
                        self.chained_cmp_next_block = null;
                    } else {
                        block_idx = try self.findIfChainEnd(p);
                    }
                },
                .while_loop => |p| {
                    const stmt = try self.decompileWhile(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    if (self.loop_next) |next| {
                        block_idx = next;
                        self.loop_next = null;
                    } else {
                        block_idx = p.exit_block;
                    }
                },
                .for_loop => |p| {
                    if (try self.tryDecompileInlineListComp(p)) |result| {
                        deinitStackValuesSlice(self.allocator, self.allocator, result.stack);
                        block_idx = result.exit_block;
                        continue;
                    }
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = p.exit_block;
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
                },
                .with_stmt => |p| {
                    const result = try self.decompileWith(p);
                    if (result.stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = result.next_block;
                },
                .match_stmt => |p| {
                    try self.emitMatchPrelude(p.subject_block, &stmts, a);
                    const result = try self.decompileMatch(p);
                    if (result.stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = result.next_block;
                },
                else => {
                    const block = &self.cfg.blocks[block_idx];
                    if (block.is_loop_header) {
                        if (try self.decompileLoopHeader(block_idx)) |result| {
                            if (result.stmt) |s| {
                                try stmts.append(a, s);
                            }
                            block_idx = result.next_block;
                            break;
                        }
                    }
                    const seed = if (block_idx == start)
                        init_stack
                    else if (block_idx < self.stack_in.len)
                        (self.stack_in[block_idx] orelse &.{})
                    else
                        &.{};
                    try self.decompileBlockIntoWithStack(block_idx, &stmts, a, seed);
                    block_idx += 1;
                },
            }
            if (block_idx <= prev_idx) {
                stmts.items.len = stmts_len;
                const seed = if (block_idx == start)
                    init_stack
                else if (block_idx < self.stack_in.len)
                    (self.stack_in[block_idx] orelse &.{})
                else
                    &.{};
                try self.decompileBlockIntoWithStack(block_idx, &stmts, a, seed);
                block_idx = prev_idx + 1;
            }
            if (block_idx <= prev_idx) {
                if (self.last_error_ctx == null) {
                    self.last_error_ctx = .{
                        .code_name = self.code.name,
                        .block_id = prev_idx,
                        .offset = self.cfg.blocks[prev_idx].start_offset,
                        .opcode = "structured_no_progress",
                    };
                }
                return error.InvalidBlock;
            }
        }

        if (stmts.items.len >= 2) {
            var i: usize = 0;
            while (i + 1 < stmts.items.len) : (i += 1) {
                const cur = stmts.items[i];
                const next = stmts.items[i + 1];
                if (cur.* == .if_stmt and self.stmtIsTerminal(next)) {
                    self.pruneTrailingTerminalInStmt(cur, next);
                }
            }
        }

        return stmts.toOwnedSlice(a);
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

            var sim = self.initSim(a, a, self.code, self.version);
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
                        try sim.simulate(inst);
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

            // Decompile handler body (seed exception stack for handler context)
            const handler_seed = if (handler_block.is_exception_handler or self.cfg.blocks[body_block].is_exception_handler) blk: {
                const e1 = try a.create(Expr);
                e1.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                const e2 = try a.create(Expr);
                e2.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                const e3 = try a.create(Expr);
                e3.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                break :blk &[_]StackValue{ .{ .expr = e1 }, .{ .expr = e2 }, .{ .expr = e3 } };
            } else &.{};

            const handler_body = try self.decompileBlockRangeWithStackAndSkip(
                body_block,
                handler_end_block,
                handler_seed,
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
        var else_end_block = first_handler;
        if (pattern.else_block) |else_start| {
            // Determine where else block ends
            if (pattern.finally_block) |finally_start| {
                else_end_block = finally_start;
            }
            // Else block runs from else_start to finally or first handler
            else_body = try self.decompileBlockRangeWithStack(
                else_start,
                else_end_block,
                &.{},
            );
            if (else_end_block >= actual_end) actual_end = else_end_block;
        }

        // Decompile finally block if present
        var final_body: []const *Stmt = &.{};
        if (pattern.finally_block) |finally_start| {
            const finally_end = pattern.exit_block orelse @as(u32, @intCast(self.cfg.blocks.len));
            final_body = try self.decompileBlockRangeWithStack(
                finally_start,
                finally_end,
                &.{},
            );
            if (finally_end >= actual_end) actual_end = finally_end;
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
                .finalbody = final_body,
            },
        };

        return .{ .stmt = try_stmt, .next_block = actual_end };
    }

    fn decompileTryBody(
        self: *Decompiler,
        start: u32,
        end: u32,
        loop_header: ?u32,
        visited: ?*std.DynamicBitSet,
    ) DecompileError![]const *Stmt {
        if (start >= end or start >= self.cfg.blocks.len) return &[_]*Stmt{};
        const start_block = &self.cfg.blocks[start];
        const prev_limit = self.br_limit;
        self.br_limit = end;
        defer self.br_limit = prev_limit;
        var has_cond = false;
        for (start_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                has_cond = true;
                break;
            }
        }

        if (has_cond) {
            const pattern = if (loop_header != null)
                try self.analyzer.detectPatternNoTryInLoop(start)
            else
                try self.analyzer.detectPatternNoTry(start);
            if (pattern == .if_stmt) {
                const if_pat = pattern.if_stmt;
                var last_stmt_idx: ?usize = null;
                for (start_block.instructions, 0..) |inst, idx| {
                    if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                    if (inst.opcode == .JUMP_BACKWARD or inst.opcode == .JUMP_BACKWARD_NO_INTERRUPT) break;
                    switch (inst.opcode) {
                        .STORE_FAST,
                        .STORE_NAME,
                        .STORE_GLOBAL,
                        .STORE_DEREF,
                        .STORE_ATTR,
                        .STORE_SUBSCR,
                        .POP_TOP,
                        .DELETE_NAME,
                        .DELETE_FAST,
                        .DELETE_GLOBAL,
                        .DELETE_DEREF,
                        .DELETE_ATTR,
                        .DELETE_SUBSCR,
                        .RETURN_VALUE,
                        .RETURN_CONST,
                        .RAISE_VARARGS,
                        => last_stmt_idx = idx + 1,
                        else => {},
                    }
                }

                const skip_cond = last_stmt_idx orelse 0;
                var local_vis: ?std.DynamicBitSet = null;
                var vis_ptr = visited;
                if (loop_header != null and vis_ptr == null) {
                    local_vis = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
                    vis_ptr = &local_vis.?;
                }
                defer if (local_vis) |*v| v.deinit();

                const a = self.arena.allocator();
                var stmt: ?*Stmt = null;
                var guard_then: ?[]const *Stmt = null;
                if (loop_header) |header| {
                    var loop_exit = self.loopBlockLeadsToContinue(if_pat.then_block, header) or
                        self.loopBlockLeadsToBreak(if_pat.then_block, header);
                    if (!loop_exit) {
                        if (if_pat.else_block) |else_id| {
                            loop_exit = self.loopBlockLeadsToContinue(else_id, header) or
                                self.loopBlockLeadsToBreak(else_id, header);
                        }
                    }
                    if (loop_exit) {
                        if (vis_ptr) |v| {
                            if (try self.loopIfParts(if_pat, header, v)) |parts| {
                                const else_cont = if (parts.else_is_continuation and parts.else_block != null) blk: {
                                    const else_id = parts.else_block.?;
                                    if (self.resolveJumpOnlyBlock(else_id) == header or self.loopBlockLeadsToContinue(else_id, header)) {
                                        break :blk true;
                                    }
                                    break :blk false;
                                } else false;
                                if (else_cont) {
                                    const else_is_jump_target = self.elseIsJumpTarget(parts.cond_op);
                                    if (else_is_jump_target) {
                                        const if_stmt = try a.create(Stmt);
                                        if_stmt.* = .{ .if_stmt = .{
                                            .condition = parts.condition,
                                            .body = parts.then_body,
                                            .else_body = parts.else_body,
                                        } };
                                        stmt = if_stmt;
                                    } else {
                                        const guard_cond = try self.guardCondForBranch(parts.condition, parts.cond_op, else_is_jump_target);
                                        var guard_body = parts.else_body;
                                        var needs_continue = true;
                                        if (guard_body.len > 0) {
                                            const last = guard_body[guard_body.len - 1];
                                            if (last.* == .continue_stmt or self.stmtIsTerminal(last)) {
                                                needs_continue = false;
                                            }
                                        }
                                        if (needs_continue) {
                                            const cont = try self.makeContinue();
                                            const next_body = try a.alloc(*Stmt, guard_body.len + 1);
                                            if (guard_body.len > 0) {
                                                std.mem.copyForwards(*Stmt, next_body[0..guard_body.len], guard_body);
                                            }
                                            next_body[guard_body.len] = cont;
                                            guard_body = next_body;
                                        }
                                        const guard_stmt = try a.create(Stmt);
                                        guard_stmt.* = .{ .if_stmt = .{
                                            .condition = guard_cond,
                                            .body = guard_body,
                                            .else_body = &.{},
                                        } };
                                        stmt = guard_stmt;
                                        guard_then = parts.then_body;
                                    }
                                } else {
                                    const if_stmt = try a.create(Stmt);
                                    if_stmt.* = .{ .if_stmt = .{
                                        .condition = parts.condition,
                                        .body = parts.then_body,
                                        .else_body = parts.else_body,
                                    } };
                                    stmt = if_stmt;
                                }
                            }
                        }
                    }
                }
                if (stmt == null) {
                    stmt = if (skip_cond > 0)
                        try self.decompileIfWithSkip(if_pat, skip_cond)
                    else
                        try self.decompileIf(if_pat);
                }
                if (stmt) |s| {
                    var stmts: std.ArrayList(*Stmt) = .{};
                    errdefer stmts.deinit(a);
                    if (skip_cond > 0) {
                        var skip_first_store = false;
                        try self.processPartialBlock(start_block, &stmts, a, &skip_first_store, skip_cond);
                    }
                    try stmts.append(a, s);
                    if (guard_then) |body| {
                        if (body.len > 0) {
                            try stmts.appendSlice(a, body);
                        }
                    }
                    var next = try self.findIfChainEnd(if_pat);
                    if (self.if_next) |override| {
                        next = override;
                        self.if_next = null;
                        self.chained_cmp_next_block = null;
                    } else if (self.chained_cmp_next_block) |chain_next| {
                        next = chain_next;
                        self.chained_cmp_next_block = null;
                    }
                    if (next < end and next < self.cfg.blocks.len) {
                        const rest = if (loop_header != null)
                            try self.decompileTryBody(next, end, loop_header, vis_ptr)
                        else
                            try self.decompileStructuredRange(next, end);
                        try stmts.appendSlice(a, rest);
                    }
                    return stmts.toOwnedSlice(a);
                }
            }
        }

        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

        var skip_store = false;
        var seed_pop = false;
        try self.processBlockStatements(
            start,
            start_block,
            &stmts,
            &skip_store,
            &seed_pop,
            true,
            loop_header,
            0,
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
        var sim = self.initSim(a, a, self.code, self.version);
        defer sim.deinit();
        sim.lenient = true;
        sim.stack.allow_underflow = true;
        for (0..3) |_| {
            const placeholder = try a.create(Expr);
            placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
            try sim.stack.push(.{ .expr = placeholder });
        }

        var exc_type: ?*Expr = null;
        var name: ?[]const u8 = null;
        var skip_first_store = false;
        var body_block: u32 = handler_block;
        var skip: usize = 0;

        var has_dup = false;
        var has_exc_cmp = false;
        var has_jump = false;
        for (block.instructions) |inst| {
            if (inst.opcode == .JUMP_IF_NOT_EXC_MATCH) {
                has_exc_cmp = true;
                has_jump = true;
                continue;
            }
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
            if (exc_type == null) {
                for (block.instructions, 0..) |inst, idx| {
                    if (inst.opcode != .LOAD_GLOBAL and inst.opcode != .LOAD_NAME and inst.opcode != .LOAD_DEREF) continue;
                    if (idx + 1 >= block.instructions.len) continue;
                    if (block.instructions[idx + 1].opcode != .JUMP_IF_NOT_EXC_MATCH) continue;
                    const exc_name = switch (inst.opcode) {
                        .LOAD_GLOBAL, .LOAD_NAME => sim.getName(inst.arg),
                        .LOAD_DEREF => sim.getDeref(inst.arg),
                        else => null,
                    };
                    if (exc_name) |n| {
                        exc_type = try self.makeName(n, .load);
                        break;
                    }
                }
            }
            var found_body = false;
            for (block.successors) |edge| {
                if (edge.edge_type == .conditional_true) {
                    body_block = edge.target;
                    found_body = true;
                    break;
                }
            }
            if (!found_body) {
                for (block.successors) |edge| {
                    if (edge.edge_type == .normal) {
                        body_block = edge.target;
                        break;
                    }
                }
            }

            if (name == null) {
                var saw_pop_top = false;
                for (block.instructions) |inst| {
                    switch (inst.opcode) {
                        .POP_TOP => {
                            saw_pop_top = true;
                            continue;
                        },
                        .STORE_FAST => if (saw_pop_top) {
                            name = sim.getLocal(inst.arg);
                            break;
                        },
                        .STORE_NAME, .STORE_GLOBAL => if (saw_pop_top) {
                            name = sim.getName(inst.arg);
                            break;
                        },
                        .STORE_DEREF => if (saw_pop_top) {
                            name = sim.getDeref(inst.arg);
                            break;
                        },
                        else => {},
                    }
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
                                v.deinit(sim.allocator, sim.stack_alloc);
                            },
                        }
                    }
                    break;
                }
                if (inst.opcode == .JUMP_IF_NOT_EXC_MATCH) {
                    if (sim.stack.pop()) |val| {
                        switch (val) {
                            .expr => |e| exc_type = e,
                            else => {
                                var v = val;
                                v.deinit(sim.allocator, sim.stack_alloc);
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
                var prev_was_pop = false;
                while (idx < body.instructions.len) {
                    const inst = body.instructions[idx];
                    switch (inst.opcode) {
                        .POP_TOP => {
                            prev_was_pop = true;
                            idx += 1;
                            continue;
                        },
                        .STORE_FAST => if (prev_was_pop and name == null) {
                            name = sim.getLocal(inst.arg);
                            idx += 1;
                            continue;
                        },
                        .STORE_NAME, .STORE_GLOBAL => if (prev_was_pop and name == null) {
                            name = sim.getName(inst.arg);
                            idx += 1;
                            continue;
                        },
                        .STORE_DEREF => if (prev_was_pop and name == null) {
                            name = sim.getDeref(inst.arg);
                            idx += 1;
                            continue;
                        },
                        else => {},
                    }
                    prev_was_pop = false;
                    break;
                }
                skip = idx;
                if (skip >= body.instructions.len) {
                    var next_body: ?u32 = null;
                    for (body.successors) |edge| {
                        if (edge.edge_type == .normal) {
                            next_body = edge.target;
                            break;
                        }
                    }
                    if (next_body) |nb| {
                        body_block = nb;
                        skip = 0;
                    }
                }
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
        const head_block = &self.cfg.blocks[start];
        var head_has_pop_except = false;
        for (head_block.instructions) |inst| {
            if (inst.opcode == .POP_EXCEPT) {
                head_has_pop_except = true;
                break;
            }
        }
        var head = head_block.*;
        if (skip > 0 and skip < head.instructions.len) {
            head.instructions = head.instructions[skip..];
        }

        if (!skip_first_store and skip == 0) {
            var has_exc_match = false;
            for (head.instructions) |inst| {
                if (inst.opcode == .CHECK_EXC_MATCH or inst.opcode == .JUMP_IF_NOT_EXC_MATCH or
                    (inst.opcode == .COMPARE_OP and inst.arg == 10))
                {
                    has_exc_match = true;
                    break;
                }
            }
            if (!has_exc_match) {
                var exc_stack: [3]StackValue = undefined;
                for (&exc_stack) |*slot| {
                    const placeholder = try a.create(Expr);
                    placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                    slot.* = .{ .expr = placeholder };
                }
                return try self.decompileStructuredRangeNoTryWithStackAllowHandlers(start, end, &exc_stack);
            }
        }

        var sim = self.initSim(a, a, self.code, self.version);
        defer sim.deinit();
        sim.lenient = true;
        sim.stack.allow_underflow = true;

        // Python pushes (type, value, traceback) on stack when entering handler
        // Use placeholder exprs so operations like COMPARE_OP work
        for (0..3) |_| {
            const placeholder = try a.create(Expr);
            placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
            try sim.stack.push(.{ .expr = placeholder });
        }

        var i: usize = 0;
        while (i < head.instructions.len) : (i += 1) {
            const inst = head.instructions[i];
            if (inst.opcode == .POP_EXCEPT) break;
            errdefer if (self.last_error_ctx == null) {
                self.last_error_ctx = .{
                    .code_name = self.code.name,
                    .block_id = start,
                    .offset = inst.offset,
                    .opcode = inst.opcode.name(),
                };
            };

            if (inst.opcode == .IMPORT_NAME) {
                if (try self.tryDecompileImportFromGroup(&sim, head.instructions, i, &stmts, a)) |end_idx| {
                    i = end_idx;
                    continue;
                }
            }

            switch (inst.opcode) {
                .STORE_FAST, .STORE_NAME, .STORE_GLOBAL, .STORE_DEREF => {
                    if (skip_store) {
                        skip_store = false;
                        try sim.simulate(inst);
                        continue;
                    }
                    const name = switch (inst.opcode) {
                        .STORE_FAST => sim.getLocal(inst.arg),
                        .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg),
                        .STORE_DEREF => sim.getDeref(inst.arg),
                        else => unreachable,
                    };
                    if (name) |n| {
                        const value = sim.stack.pop() orelse {
                            try sim.simulate(inst);
                            continue;
                        };
                        if (try self.handleStoreValue(n, value)) |stmt| {
                            try stmts.append(a, stmt);
                        }
                    } else {
                        try sim.simulate(inst);
                    }
                },
                .POP_TOP => {
                    if (sim.stack.len() == 0) continue;
                    const val = sim.stack.pop().?;
                    switch (val) {
                        .expr => |expr| {
                            if (self.makeExprStmt(expr)) |stmt| {
                                try stmts.append(a, stmt);
                            } else |err| {
                                if (err != error.SkipStatement) return err;
                            }
                        },
                        else => val.deinit(sim.allocator, sim.stack_alloc),
                    }
                },
                .RAISE_VARARGS, .DELETE_NAME, .DELETE_FAST, .DELETE_GLOBAL, .DELETE_DEREF, .DELETE_ATTR, .DELETE_SUBSCR => {
                    if (try self.tryEmitStatement(inst, &sim)) |stmt| {
                        try stmts.append(a, stmt);
                    }
                },
                else => {
                    try sim.simulate(inst);
                },
            }
        }

        if (head_has_pop_except) {
            return stmts.toOwnedSlice(a);
        }

        if (start + 1 < end) {
            var exc_stack: [3]StackValue = undefined;
            for (&exc_stack) |*slot| {
                const placeholder = try a.create(Expr);
                placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                slot.* = .{ .expr = placeholder };
            }
            const rest = try self.decompileStructuredRangeNoTryWithStackAllowHandlers(start + 1, end, &exc_stack);
            try stmts.appendSlice(a, rest);
        }

        return stmts.toOwnedSlice(a);
    }

    fn decompileHandlerBodyLinear(
        self: *Decompiler,
        start: u32,
        end: u32,
        skip: usize,
    ) DecompileError![]const *Stmt {
        if (start >= end or start >= self.cfg.blocks.len) return &[_]*Stmt{};
        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

        var sim = self.initSim(a, a, self.code, self.version);
        defer sim.deinit();
        sim.lenient = true;
        sim.stack.allow_underflow = true;

        for (0..3) |_| {
            const placeholder = try a.create(Expr);
            placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
            try sim.stack.push(.{ .expr = placeholder });
        }

        var bid = start;
        var first = true;
        while (bid < end and bid < self.cfg.blocks.len) : (bid += 1) {
            const block = &self.cfg.blocks[bid];
            const skip_first = if (first) skip else 0;
            try self.processBlockWithSimAndSkip(block, &sim, &stmts, a, skip_first);
            first = false;
        }

        return stmts.toOwnedSlice(a);
    }

    fn collectReachableNoExceptionInto(
        self: *Decompiler,
        start: u32,
        handler_set: *const GenSet,
        visited: *GenSet,
        queue: *std.ArrayListUnmanaged(u32),
        allow_start_in_handler: bool,
        allow_loop_back: bool,
    ) DecompileError!void {
        visited.reset();
        queue.clearRetainingCapacity();

        if (start >= self.cfg.blocks.len) return;
        if (handler_set.isSet(start) and !allow_start_in_handler) return;

        try visited.set(self.allocator, start);
        try queue.append(self.allocator, start);

        while (queue.items.len > 0) {
            const node = queue.items[queue.items.len - 1];
            queue.items.len -= 1;
            const block = &self.cfg.blocks[node];
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (!allow_loop_back and edge.edge_type == .loop_back) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (handler_set.isSet(edge.target)) continue;
                if (!visited.isSet(edge.target)) {
                    try visited.set(self.allocator, edge.target);
                    try queue.append(self.allocator, edge.target);
                }
            }
        }
    }

    fn collectReachableNoExceptionFromStarts(
        self: *Decompiler,
        starts: []const u32,
        handler_set: *const GenSet,
        visited: *GenSet,
        queue: *std.ArrayListUnmanaged(u32),
        allow_loop_back: bool,
    ) DecompileError!void {
        visited.reset();
        queue.clearRetainingCapacity();

        for (starts) |start| {
            if (start >= self.cfg.blocks.len) continue;
            if (visited.isSet(start)) continue;
            try visited.set(self.allocator, start);
            try queue.append(self.allocator, start);
        }

        while (queue.items.len > 0) {
            const node = queue.items[queue.items.len - 1];
            queue.items.len -= 1;
            const block = &self.cfg.blocks[node];
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (!allow_loop_back and edge.edge_type == .loop_back) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (handler_set.isSet(edge.target)) continue;
                if (!visited.isSet(edge.target)) {
                    try visited.set(self.allocator, edge.target);
                    try queue.append(self.allocator, edge.target);
                }
            }
        }
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
                .PUSH_EXC_INFO, .CHECK_EXC_MATCH, .POP_EXCEPT, .JUMP_IF_NOT_EXC_MATCH => return true,
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

    fn hasExceptionSuccessor(self: *Decompiler, block: *const BasicBlock) bool {
        _ = self;
        for (block.successors) |edge| {
            if (edge.edge_type == .exception) return true;
        }
        return false;
    }

    fn hasWithExitCleanup(self: *Decompiler, block: *const BasicBlock) bool {
        _ = self;
        if (block.instructions.len < 4) return false;
        var i: usize = 0;
        while (i + 3 < block.instructions.len) : (i += 1) {
            const a = block.instructions[i];
            const b = block.instructions[i + 1];
            const c = block.instructions[i + 2];
            const d = block.instructions[i + 3];
            if (a.opcode == .LOAD_CONST and
                b.opcode == .DUP_TOP and
                c.opcode == .DUP_TOP and
                d.opcode == .CALL_FUNCTION and d.arg == 3)
            {
                return true;
            }
        }
        return false;
    }

    fn needsExceptionSeed(self: *Decompiler, block_id: u32, block: *const BasicBlock) bool {
        _ = block_id;
        if (block.is_exception_handler or self.hasExceptionHandlerOpcodes(block)) return true;
        for (block.predecessors) |pred_id| {
            if (pred_id >= self.cfg.blocks.len) continue;
            const pred = &self.cfg.blocks[pred_id];
            if (pred.is_exception_handler or self.hasExceptionHandlerOpcodes(pred)) return true;
        }
        return false;
    }

    fn exceptionSeedCount(self: *Decompiler, block_id: u32, block: *const BasicBlock) usize {
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .ROT_FOUR, .WITH_EXCEPT_START => return 4,
                else => {},
            }
        }
        if (!self.needsExceptionSeed(block_id, block)) return 0;
        return 3;
    }

    /// Decompile a for loop pattern.
    fn decompileFor(self: *Decompiler, pattern: ctrl.ForPattern) DecompileError!?*Stmt {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        if (self.loop_depth > 128) return null;
        if (self.loop_in_progress) |*set| {
            if (set.isSet(pattern.header_block)) return null;
            set.set(pattern.header_block);
            defer set.unset(pattern.header_block);
        }
        // Get the iterator expression from the setup block
        // Python 3+: ... GET_ITER
        // Python 1.x-2.2: ... LOAD_CONST 0 (sequence on TOS, index pushed)
        const setup = &self.cfg.blocks[pattern.setup_block];
        const header = &self.cfg.blocks[pattern.header_block];

        var iter_sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer iter_sim.deinit();

        if (pattern.setup_block < self.stack_in.len) {
            if (self.stack_in[pattern.setup_block]) |entry| {
                for (entry) |val| {
                    const cloned = try iter_sim.cloneStackValue(val);
                    try iter_sim.stack.push(cloned);
                }
            }
        }

        const header_term = header.terminator() orelse return null;
        if (header_term.opcode == .FOR_LOOP) {
            // Python 1.x-2.2: Setup block pushes sequence, header block adds index
            // Simulate setup block completely, it should leave sequence on TOS
            for (setup.instructions) |inst| {
                try iter_sim.simulate(inst);
            }
            // After simulating setup, stack should be [seq, idx, ...other stuff]
            // But we only want the sequence. Pop everything after the sequence.
            // Actually, the last LOAD_CONST in setup pushes the index.
            // So before the last LOAD_CONST, TOS is the sequence.
            // Simplification: Assume TOS-1 is sequence, TOS is index
            if (iter_sim.stack.items.items.len >= 2) {
                _ = iter_sim.stack.pop(); // pop index
            }
        } else {
            // Python 3+: GET_ITER
            var last_get_iter: ?usize = null;
            for (setup.instructions, 0..) |inst, idx| {
                if (inst.opcode == .GET_ITER) {
                    last_get_iter = idx;
                }
            }
            const stop_idx = last_get_iter orelse setup.instructions.len;
            for (setup.instructions[0..stop_idx]) |inst| {
                try iter_sim.simulate(inst);
            }
        }

        const iter_expr = try iter_sim.stack.popExpr();

        // Get the loop target from the body block's first STORE_* or UNPACK_SEQUENCE
        const body = &self.cfg.blocks[pattern.body_block];
        const a = self.arena.allocator();
        var target_sim = self.initSim(a, a, self.code, self.version);
        defer target_sim.deinit();
        var target: *Expr = undefined;
        var found_target = false;

        for (body.instructions, 0..) |inst, inst_idx| {
            switch (inst.opcode) {
                .STORE_FAST => {
                    const name = if (self.code.varnames.len > inst.arg)
                        self.code.varnames[inst.arg]
                    else
                        "_";
                    target = try self.makeName(name, .store);
                    found_target = true;
                    break;
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    const name = if (self.code.names.len > inst.arg)
                        self.code.names[inst.arg]
                    else
                        "_";
                    target = try self.makeName(name, .store);
                    found_target = true;
                    break;
                },
                .UNPACK_SEQUENCE, .UNPACK_EX => {
                    const unpack = try self.collectUnpackTgts(&target_sim, body.instructions, inst_idx, a);
                    if (unpack != null and unpack.?.ok) {
                        const tuple_expr = try a.create(Expr);
                        tuple_expr.* = .{ .tuple = .{ .elts = unpack.?.tgts, .ctx = .store } };
                        target = tuple_expr;
                        found_target = true;
                        break;
                    }
                    const cnt = if (inst.opcode == .UNPACK_EX) blk: {
                        const before = inst.arg & 0xFF;
                        const after = (inst.arg >> 8) & 0xFF;
                        break :blk before + 1 + after;
                    } else inst.arg;
                    const star_pos: ?u32 = if (inst.opcode == .UNPACK_EX) blk: {
                        const before = inst.arg & 0xFF;
                        break :blk before;
                    } else null;
                    if (cnt == 0) {
                        target = try a.create(Expr);
                        target.* = .{ .tuple = .{ .elts = &.{}, .ctx = .store } };
                    } else {
                        const cnt_usize: usize = @intCast(cnt);
                        var elts = try a.alloc(*Expr, cnt_usize);
                        var i: usize = 0;
                        while (i < cnt_usize) : (i += 1) {
                            var t = try self.makeName("_", .store);
                            t = try self.starTgt(a, t, i, star_pos);
                            elts[i] = t;
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
            target = try self.makeName("_", .store);
        }

        // Decompile the body (skip the first STORE_FAST which is the target)
        const body_stmts = try self.decompileForBody(pattern.body_block, pattern.header_block);
        var else_body: []const *Stmt = &.{};
        if (pattern.else_block) |else_id| {
            const end_block: ?u32 = if (pattern.exit_block > else_id) pattern.exit_block else null;
            else_body = try self.decompileBranchRange(else_id, end_block, &.{}, 0);
        }
        const stmt = try a.create(Stmt);
        stmt.* = .{ .for_stmt = .{
            .target = target,
            .iter = iter_expr,
            .body = body_stmts,
            .else_body = else_body,
            .type_comment = null,
            .is_async = false,
        } };

        return stmt;
    }

    /// Decompile a for loop body using loop-region membership.
    fn decompileForBody(self: *Decompiler, body_block_id: u32, header_block_id: u32) DecompileError![]const *Stmt {
        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer visited.deinit();

        var skip_first_store = true;
        var seed_pop = false;
        var block_idx = body_block_id;
        var loop_end_offset: ?u32 = null;
        if (header_block_id < self.cfg.blocks.len) {
            const header = &self.cfg.blocks[header_block_id];
            for (header.successors) |edge| {
                if (edge.edge_type == .conditional_false and edge.target < self.cfg.blocks.len) {
                    loop_end_offset = self.cfg.blocks[edge.target].start_offset;
                    break;
                }
            }
        }

        while (block_idx < self.cfg.blocks.len) {
            const block = &self.cfg.blocks[block_idx];
            if (loop_end_offset) |end_off| {
                if (block.start_offset >= end_off) break;
            }
            if (self.consumed.isSet(block_idx)) {
                block_idx += 1;
                continue;
            }
            if (!self.analyzer.inLoop(block_idx, header_block_id)) {
                block_idx += 1;
                continue;
            }
            if (block_idx == header_block_id and block_idx != body_block_id) break;

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
                    try self.processPartialBlock(block, &stmts, a, &skip_first_store, null);

                    const parts = try self.loopIfParts(p, header_block_id, &visited) orelse {
                        block_idx += 1;
                        continue;
                    };
                    if (parts.else_is_continuation and parts.else_block != null and self.isTrueJump(parts.cond_op)) {
                        const else_is_jump_target = self.elseIsJumpTarget(parts.cond_op);
                        const prefer_if = parts.condition.* == .bool_op;
                        if ((else_is_jump_target and parts.else_body.len == 0 and parts.then_body.len > 0) or
                            (prefer_if and !else_is_jump_target and parts.else_body.len == 0 and parts.then_body.len > 0 and !self.bodyEndsTerminal(parts.then_body)))
                        {
                            const if_stmt = try a.create(Stmt);
                            if_stmt.* = .{ .if_stmt = .{
                                .condition = parts.condition,
                                .body = parts.then_body,
                                .else_body = &.{},
                            } };
                            try stmts.append(a, if_stmt);
                        } else {
                            const guard_cond = try self.guardCondFromJump(parts.condition, parts.cond_op);
                            var guard_body = parts.else_body;
                            var needs_continue = true;
                            if (guard_body.len > 0) {
                                const last = guard_body[guard_body.len - 1];
                                if (last.* == .continue_stmt or self.stmtIsTerminal(last)) {
                                    needs_continue = false;
                                }
                            }
                            if (needs_continue) {
                                const cont = try self.makeContinue();
                                const next_body = try a.alloc(*Stmt, guard_body.len + 1);
                                if (guard_body.len > 0) {
                                    std.mem.copyForwards(*Stmt, next_body[0..guard_body.len], guard_body);
                                }
                                next_body[guard_body.len] = cont;
                                guard_body = next_body;
                            }
                            const guard_stmt = try a.create(Stmt);
                            guard_stmt.* = .{ .if_stmt = .{
                                .condition = guard_cond,
                                .body = guard_body,
                                .else_body = &.{},
                            } };
                            try stmts.append(a, guard_stmt);
                            if (parts.then_body.len > 0) {
                                try stmts.appendSlice(a, parts.then_body);
                            }
                        }
                    } else {
                        const if_stmt = try a.create(Stmt);
                        if_stmt.* = .{ .if_stmt = .{
                            .condition = parts.condition,
                            .body = parts.then_body,
                            .else_body = parts.else_body,
                        } };
                        try stmts.append(a, if_stmt);
                    }
                    if (try self.nextLoopBlockAfterIf(p, header_block_id, block_idx, null)) |next_id| {
                        block_idx = next_id;
                        continue;
                    }
                    break;
                },
                .for_loop => |p| {
                    if (try self.tryDecompileInlineListComp(p)) |result| {
                        deinitStackValuesSlice(self.allocator, self.allocator, result.stack);
                        block_idx = result.exit_block;
                        continue;
                    }
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    self.markLoopVisited(p.header_block, &visited);
                    block_idx = p.exit_block;
                    continue;
                },
                .while_loop => |p| {
                    const stmt = try self.decompileWhile(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    self.markLoopVisited(p.header_block, &visited);
                    if (self.loop_next) |next| {
                        block_idx = next;
                        self.loop_next = null;
                    } else {
                        block_idx = p.exit_block;
                    }
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
                    const result = try self.decompileTryWithLoop(p, header_block_id, &visited);
                    const leave_loop = self.tryNeedsBreak(&p, header_block_id);
                    if (result.stmt) |s| {
                        if (leave_loop) {
                            try self.appendTryBreak(s);
                        }
                        try stmts.append(a, s);
                    }
                    if (leave_loop) break;
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
                        0,
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

    fn markLoopVisited(self: *Decompiler, header_id: u32, visited: *std.DynamicBitSet) void {
        if (self.analyzer.loopSet(header_id)) |body| {
            visited.setUnion(body.*);
        }
    }

    fn resolveJumpOnlyBlock(self: *Decompiler, block_id: u32) u32 {
        var cur = block_id;
        var steps: usize = 0;
        while (cur < self.cfg.blocks.len and steps < 8) {
            const blk = &self.cfg.blocks[cur];
            const insts = blk.instructions;
            if (insts.len == 0) break;
            var jump_inst: ?decoder.Instruction = null;
            if (insts.len == 1) {
                const inst = insts[0];
                if (inst.opcode == .JUMP_FORWARD or inst.opcode == .JUMP_ABSOLUTE) {
                    jump_inst = inst;
                } else break;
            } else {
                const last = insts[insts.len - 1];
                if (last.opcode != .JUMP_FORWARD and last.opcode != .JUMP_ABSOLUTE) break;
                var cleanup_only = true;
                for (insts[0 .. insts.len - 1]) |inst| {
                    switch (inst.opcode) {
                        .POP_BLOCK, .POP_TOP, .POP_EXCEPT, .END_FINALLY, .END_FOR, .NOP => {},
                        else => {
                            cleanup_only = false;
                            break;
                        },
                    }
                }
                if (!cleanup_only) break;
                jump_inst = last;
            }
            if (jump_inst) |inst| {
                if (inst.jumpTarget(self.cfg.version)) |target_offset| {
                    if (self.cfg.blockAtOffset(target_offset)) |target_id| {
                        if (target_id == cur) break;
                        cur = target_id;
                        steps += 1;
                        continue;
                    }
                }
            }
            if (self.blockIsCleanupOnly(blk)) {
                var next: ?u32 = null;
                for (blk.successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    if (next != null) {
                        next = null;
                        break;
                    }
                    next = edge.target;
                }
                if (next) |target_id| {
                    if (target_id == cur) break;
                    cur = target_id;
                    steps += 1;
                    continue;
                }
            }
            break;
        }
        return cur;
    }

    fn blockIsCleanupOnly(self: *Decompiler, block: *const cfg_mod.BasicBlock) bool {
        _ = self;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .POP_BLOCK, .POP_TOP, .POP_EXCEPT, .END_FINALLY, .END_FOR, .NOP => {},
                else => return false,
            }
        }
        return true;
    }

    fn loopBreakTarget(self: *Decompiler, block_id: u32, loop_header: u32) ?u32 {
        if (block_id >= self.cfg.blocks.len) return null;
        const blk = &self.cfg.blocks[block_id];
        const term = blk.terminator() orelse return null;
        switch (term.opcode) {
            .JUMP_FORWARD,
            .JUMP_BACKWARD,
            .JUMP_BACKWARD_NO_INTERRUPT,
            .JUMP_ABSOLUTE,
            => {},
            else => return null,
        }
        if (term.jumpTarget(self.cfg.version)) |target_offset| {
            if (self.cfg.blockAtOffset(target_offset)) |target_id| {
                if (!self.analyzer.inLoop(target_id, loop_header)) return target_id;
            }
        }
        return null;
    }

    fn loopBlockLeadsToBreak(self: *Decompiler, block_id: u32, loop_header: u32) bool {
        if (self.loopBreakTarget(block_id, loop_header) != null) return true;
        if (block_id >= self.cfg.blocks.len) return false;
        const blk = &self.cfg.blocks[block_id];
        if (!self.blockIsCleanupOnly(blk)) return false;
        var succ: ?u32 = null;
        for (blk.successors) |edge| {
            if (edge.edge_type == .exception) continue;
            if (succ != null) return false;
            succ = edge.target;
        }
        if (succ == null) return false;
        return switch (self.analyzer.detectLoopExit(succ.?, &[_]u32{loop_header})) {
            .break_stmt => true,
            else => false,
        };
    }

    fn loopBlockLeadsToContinue(self: *Decompiler, block_id: u32, loop_header: u32) bool {
        var cur = block_id;
        var steps: usize = 0;
        while (cur < self.cfg.blocks.len and steps < 8) : (steps += 1) {
            const blk = &self.cfg.blocks[cur];
            const jump_only = self.resolveJumpOnlyBlock(cur) != cur;
            if (!jump_only and !self.blockIsCleanupOnly(blk)) return false;
            const exit = self.analyzer.detectLoopExit(cur, &[_]u32{loop_header});
            switch (exit) {
                .continue_stmt => return true,
                else => {},
            }
            var next: ?u32 = null;
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (next != null) return false;
                next = edge.target;
            }
            if (next == null) return false;
            const next_id = next.?;
            if (next_id == loop_header) return true;
            if (!self.analyzer.inLoop(next_id, loop_header)) return false;
            if (next_id == cur) return false;
            var pred_count: u32 = 0;
            for (self.cfg.blocks[next_id].predecessors) |pred_id| {
                if (pred_id >= self.cfg.blocks.len) continue;
                const pred = &self.cfg.blocks[pred_id];
                for (pred.successors) |edge| {
                    if (edge.target != next_id) continue;
                    if (edge.edge_type == .exception) continue;
                    pred_count += 1;
                    break;
                }
                if (pred_count > 1) return false;
            }
            if (pred_count == 0) return false;
            cur = next_id;
        }
        return false;
    }

    fn blockLeadsToHeader(self: *Decompiler, block_id: u32, loop_header: u32) bool {
        var cur = block_id;
        var steps: usize = 0;
        while (cur < self.cfg.blocks.len and steps < 8) : (steps += 1) {
            var next: ?u32 = null;
            for (self.cfg.blocks[cur].successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (next != null) return false;
                next = edge.target;
            }
            if (next == null) return false;
            const next_id = next.?;
            if (next_id == loop_header) return true;
            if (next_id == cur) return false;
            cur = next_id;
        }
        return false;
    }

    fn handlerIsContinue(self: *Decompiler, start: u32, end: u32, loop_header: u32) bool {
        var bid = start;
        while (bid < end and bid < self.cfg.blocks.len) : (bid += 1) {
            if (self.cfg.blocks[bid].is_exception_handler) continue;
            const exit = self.analyzer.detectLoopExit(bid, &[_]u32{loop_header});
            if (exit == .continue_stmt and !self.isLoopTailBack(bid, loop_header)) return true;
        }
        return false;
    }

    fn isLoopTailBack(self: *Decompiler, block_id: u32, loop_header: u32) bool {
        if (block_id >= self.cfg.blocks.len) return false;
        const blk = &self.cfg.blocks[block_id];
        if (!self.hasLoopBackEdge(blk, loop_header)) return false;
        const body = self.analyzer.loopSet(loop_header) orelse return false;
        const off = blk.start_offset;
        var i: u32 = 0;
        while (i < self.cfg.blocks.len) : (i += 1) {
            if (i == loop_header) continue;
            if (!body.isSet(@intCast(i))) continue;
            if (self.cfg.blocks[i].predecessors.len == 0) continue;
            if (self.cfg.blocks[i].start_offset > off) return false;
        }
        return true;
    }

    fn hasSingleNormalSuccessor(self: *Decompiler, block_id: u32, target: u32) bool {
        if (block_id >= self.cfg.blocks.len) return false;
        const blk = &self.cfg.blocks[block_id];
        var count: u32 = 0;
        var only: ?u32 = null;
        for (blk.successors) |edge| {
            if (edge.edge_type == .exception) continue;
            count += 1;
            only = edge.target;
            if (count > 1) return false;
        }
        return count == 1 and only.? == target;
    }

    fn continuesToHeader(
        self: *Decompiler,
        start: u32,
        header: u32,
        path_out: ?*std.ArrayListUnmanaged(u32),
    ) DecompileError!bool {
        var cur = start;
        var steps: usize = 0;
        if (path_out) |p| {
            p.* = .{};
            try p.append(self.arena.allocator(), cur);
        }
        while (cur < self.cfg.blocks.len and steps < 8) {
            if (self.jumpTargetIfJumpOnlyEdge(cur, true, true)) |target| {
                if (path_out) |p| {
                    try p.append(self.arena.allocator(), target);
                }
                return target == header;
            }
            const blk = &self.cfg.blocks[cur];
            var only_cleanup = true;
            for (blk.instructions) |inst| {
                switch (inst.opcode) {
                    .POP_BLOCK, .POP_TOP, .NOP, .NOT_TAKEN, .CACHE => {},
                    else => {
                        only_cleanup = false;
                        break;
                    },
                }
            }
            if (!only_cleanup) return false;
            var next: ?u32 = null;
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (next != null) return false;
                next = edge.target;
            }
            if (next == null) return false;
            cur = next.?;
            steps += 1;
            if (path_out) |p| {
                try p.append(self.arena.allocator(), cur);
            }
        }
        return false;
    }

    fn guardBranchToHeader(
        self: *Decompiler,
        block: *const cfg_mod.BasicBlock,
        term: decoder.Instruction,
        header: u32,
        trace_on: bool,
    ) DecompileError!?GuardBranch {
        const target_off = term.jumpTarget(self.cfg.version) orelse return null;
        const jump_id = self.cfg.blockAtOffset(target_off) orelse return null;
        var fall_id: ?u32 = null;
        for (block.successors) |edge| {
            if (edge.edge_type == .exception) continue;
            if (edge.target == jump_id) continue;
            if (fall_id != null) return null;
            fall_id = edge.target;
        }
        if (fall_id == null) return null;
        var jump_path: std.ArrayListUnmanaged(u32) = .{};
        var fall_path: std.ArrayListUnmanaged(u32) = .{};
        const jump_cont = try self.continuesToHeader(
            jump_id,
            header,
            if (trace_on) &jump_path else null,
        );
        const fall_cont = try self.continuesToHeader(
            fall_id.?,
            header,
            if (trace_on) &fall_path else null,
        );
        if (jump_cont == fall_cont) return null;
        if (jump_cont and self.elseIsJumpTarget(term.opcode)) return null;
        if (jump_cont) {
            return .{
                .target = jump_id,
                .taken = true,
                .path = if (trace_on) jump_path.items else &.{},
            };
        }
        return .{
            .target = fall_id.?,
            .taken = false,
            .path = if (trace_on) fall_path.items else &.{},
        };
    }

    fn writeTrace(self: *Decompiler, value: anytype) DecompileError!void {
        const file = self.trace_file orelse return;
        var buf: [2048]u8 = undefined;
        var writer = file.writerStreaming(&buf);
        const out = &writer.interface;
        try std.json.Stringify.value(value, .{}, out);
        try out.writeAll("\n");
        try out.flush();
    }

    fn emitDecisionTrace(
        self: *Decompiler,
        block_id: u32,
        note: []const u8,
        cond: ?*Expr,
    ) DecompileError!void {
        if (!self.trace_decisions or self.trace_file == null) return;
        const cond_text = if (cond) |c| try self.exprToString(c) else null;
        const ev = DecisionTrace{
            .kind = "decision",
            .block = block_id,
            .note = note,
            .cond = cond_text,
        };
        try self.writeTrace(ev);
    }

    fn exprToString(self: *Decompiler, expr: *const Expr) DecompileError![]const u8 {
        var cg = codegen.Writer.init(self.arena.allocator());
        defer cg.deinit(self.arena.allocator());
        try cg.writeExpr(self.arena.allocator(), expr);
        return try cg.getOutput(self.arena.allocator());
    }

    fn stackTraceVal(self: *Decompiler, val: StackValue) DecompileError!TraceStackVal {
        return switch (val) {
            .expr => |e| .{ .tag = "expr", .text = try self.exprToString(e) },
            .function_obj => |f| .{ .tag = "func", .text = f.code.name },
            .class_obj => |c| .{ .tag = "class", .text = c.name },
            .comp_builder => .{ .tag = "comp_builder", .text = null },
            .comp_obj => |c| .{ .tag = "comp", .text = @tagName(c.kind) },
            .code_obj => |c| .{ .tag = "code", .text = c.name },
            .import_module => |m| .{ .tag = "import", .text = m.module },
            .null_marker => .{ .tag = "null", .text = null },
            .saved_local => |name| .{ .tag = "saved_local", .text = name },
            .unknown => .{ .tag = "unknown", .text = null },
        };
    }

    fn stackTraceSlice(self: *Decompiler, vals: []const StackValue) DecompileError![]const TraceStackVal {
        const a = self.arena.allocator();
        if (vals.len == 0) return &.{};
        const out = try a.alloc(TraceStackVal, vals.len);
        for (vals, 0..) |val, idx| {
            out[idx] = try self.stackTraceVal(val);
        }
        return out;
    }

    fn emitGuardTrace(
        self: *Decompiler,
        block_id: u32,
        header_id: u32,
        term: decoder.Instruction,
        target_id: u32,
        guard_cond: *Expr,
        insert_idx: usize,
        path: []const u32,
    ) DecompileError!void {
        if (!self.trace_loop_guards or self.trace_file == null) return;
        const stack_vals = if (block_id < self.stack_in.len)
            (self.stack_in[block_id] orelse &.{})
        else
            &.{};
        const stack_in = try self.stackTraceSlice(stack_vals);
        const guard_expr = try self.exprToString(guard_cond);
        const ev = GuardTrace{
            .kind = "loop_guard",
            .block = block_id,
            .header = header_id,
            .term_op = @tagName(term.opcode),
            .target = target_id,
            .continues_path = path,
            .stack_in = stack_in,
            .guard_expr = guard_expr,
            .insert_idx = insert_idx,
        };
        try self.writeTrace(ev);
    }

    fn traceSimBlock(self: *Decompiler, block_id: u32) DecompileError!void {
        if (self.trace_file == null) return;
        const target = self.trace_sim_block orelse return;
        if (target != block_id) return;
        if (block_id >= self.cfg.blocks.len) return error.InvalidBlock;
        const block = &self.cfg.blocks[block_id];
        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        sim.lenient = true;
        sim.stack.allow_underflow = true;
        if (block_id < self.stack_in.len) {
            if (self.stack_in[block_id]) |entry| {
                for (entry) |val| {
                    const cloned = try sim.cloneStackValue(val);
                    try sim.stack.push(cloned);
                }
            }
        }
        for (block.instructions) |inst| {
            const before = try self.stackTraceSlice(sim.stack.items.items);
            try sim.simulate(inst);
            const after = try self.stackTraceSlice(sim.stack.items.items);
            const ev = SimTrace{
                .kind = "sim_step",
                .block = block_id,
                .offset = inst.offset,
                .op = @tagName(inst.opcode),
                .arg = inst.arg,
                .stack_before = before,
                .stack_after = after,
            };
            try self.writeTrace(ev);
            if (block.terminator()) |term| {
                if (term.offset == inst.offset) break;
            }
        }
    }

    fn emitStoreSubscr(
        self: *Decompiler,
        sim: *SimContext,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
    ) DecompileError!void {
        const a = self.arena.allocator();
        const key = try sim.stack.popExpr();
        const container = try sim.stack.popExpr();
        const annotation = try sim.stack.popExpr();

        // Check for variable annotation pattern: __annotations__['varname'] = type
        if (container.* == .name and std.mem.eql(u8, container.name.id, "__annotations__") and
            key.* == .constant and key.constant == .string)
        {
            const var_name = key.constant.string;
            const target = try self.makeName(var_name, .store);

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
            try stmts.append(stmts_allocator, stmt);
        } else {
            const subscript = try a.create(Expr);
            subscript.* = .{ .subscript = .{
                .value = container,
                .slice = key,
                .ctx = .store,
            } };
            const stmt = try self.makeAssign(subscript, annotation);
            try stmts.append(stmts_allocator, stmt);
        }
    }

    fn emitStoreSlice(
        self: *Decompiler,
        sim: *SimContext,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
    ) DecompileError!void {
        const a = self.arena.allocator();
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
        try stmts.append(stmts_allocator, stmt);
    }

    fn emitStoreAttr(
        self: *Decompiler,
        sim: *SimContext,
        instructions: []const decoder.Instruction,
        idx: *usize,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
        skip_first: usize,
        limit: ?usize,
    ) DecompileError!void {
        const a = self.arena.allocator();
        const real_idx = skip_first + idx.*;
        const has_dup_before = if (real_idx >= 2) blk: {
            const maybe_dup = instructions[real_idx - 2];
            break :blk maybe_dup.opcode == .DUP_TOP or maybe_dup.opcode == .COPY;
        } else false;
        const next_is_unpack = blk: {
            const next_idx = idx.* + 1;
            if (next_idx >= instructions.len) break :blk false;
            if (limit) |lim| {
                if (next_idx >= lim) break :blk false;
            }
            break :blk instructions[next_idx].opcode == .UNPACK_SEQUENCE;
        };

        // If part of a chain followed by UNPACK_SEQUENCE, defer to UNPACK handler
        if (has_dup_before and next_is_unpack) {
            const container_val = sim.stack.pop() orelse return error.StackUnderflow;
            _ = sim.stack.pop() orelse return error.StackUnderflow; // pop dup'd value
            if (container_val == .expr) {
                const attr_name = sim.getName(instructions[idx.*].arg) orelse "<unknown>";
                const target = try self.makeAttribute(container_val.expr, attr_name, .store);
                try self.pending_chain_targets.append(self.allocator, target);
            }
            return;
        }

        const is_chain = has_dup_before;

        if (is_chain) {
            // This is an attribute chain assignment
            var targets: std.ArrayList(*Expr) = .{};

            // Build first target from current instruction's context
            const container_val = sim.stack.pop() orelse return error.StackUnderflow;
            _ = sim.stack.pop() orelse return error.StackUnderflow; // pop dup'd value

            if (container_val == .expr) {
                const attr_name = sim.getName(instructions[idx.*].arg) orelse "<unknown>";
                const first_target = try self.makeAttribute(container_val.expr, attr_name, .store);
                try targets.append(a, first_target);
            }

            // Look ahead for more attribute chain targets
            var j: usize = idx.* + 1;
            while (j < instructions.len) {
                if (limit) |lim| {
                    if (j >= lim) break;
                }
                const next_inst = instructions[j];
                if (next_inst.opcode == .DUP_TOP or next_inst.opcode == .COPY) {
                    // DUP + attr target
                    try sim.simulate(next_inst);
                    if (j + 2 < instructions.len) {
                        if (limit) |lim| {
                            if (j + 2 >= lim) break;
                        }
                        const load_inst = instructions[j + 1];
                        const store_inst = instructions[j + 2];
                        if (store_inst.opcode == .STORE_ATTR) {
                            try sim.simulate(load_inst);
                            const cont_val = sim.stack.pop() orelse return error.StackUnderflow;
                            _ = sim.stack.pop() orelse return error.StackUnderflow;
                            if (cont_val == .expr) {
                                const attr = sim.getName(store_inst.arg) orelse "<unknown>";
                                const target = try self.makeAttribute(cont_val.expr, attr, .store);
                                try targets.append(a, target);
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
                    // Final attr target (no DUP), possibly through LOAD_ATTR chain.
                    if (limit) |lim| {
                        if (j >= lim) break;
                    }
                    var k: usize = j;
                    try sim.simulate(instructions[k]);
                    k += 1;
                    while (k < instructions.len and instructions[k].opcode == .LOAD_ATTR) {
                        if (limit) |lim| {
                            if (k >= lim) break;
                        }
                        try sim.simulate(instructions[k]);
                        k += 1;
                    }
                    if (k < instructions.len) {
                        if (limit) |lim| {
                            if (k >= lim) break;
                        }
                        if (instructions[k].opcode == .STORE_ATTR) {
                            const cont_val = sim.stack.pop() orelse return error.StackUnderflow;
                            if (cont_val == .expr) {
                                const attr = sim.getName(instructions[k].arg) orelse "<unknown>";
                                const target = try self.makeAttribute(cont_val.expr, attr, .store);
                                try targets.append(a, target);
                            }
                            j = k + 1;
                        }
                    }
                    break;
                } else {
                    break;
                }
            }

            // Get the value
            const value = sim.stack.pop() orelse return error.StackUnderflow;
            if (value == .expr and targets.items.len > 0) {
                const stmt = try a.create(Stmt);
                stmt.* = .{ .assign = .{
                    .targets = targets.items,
                    .value = value.expr,
                    .type_comment = null,
                } };
                try stmts.append(stmts_allocator, stmt);
            }
            idx.* = j - 1;
            return;
        }

        // Regular single attribute assignment
        const container_val = sim.stack.pop() orelse {
            try sim.simulate(instructions[idx.*]);
            return;
        };
        const value_val = sim.stack.pop() orelse {
            try sim.simulate(instructions[idx.*]);
            return;
        };

        const container = if (container_val == .expr) container_val.expr else return;
        const value = if (value_val == .expr) value_val.expr else return;

        const attr_name = sim.getName(instructions[idx.*].arg) orelse "<unknown>";
        const attr_expr = try self.makeAttribute(container, attr_name, .store);
        const stmt = try self.makeAssign(attr_expr, value);
        try stmts.append(stmts_allocator, stmt);
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
        skip_first: usize,
    ) DecompileError!void {
        const a = self.arena.allocator();
        var sim = self.initSim(a, a, self.code, self.version);
        defer sim.deinit();
        if (self.hasExceptionSuccessor(block) or self.hasWithExitCleanup(block)) {
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }
        const seed = if (block_id < self.stack_in.len) blk: {
            if (self.stack_in[block_id]) |entry| break :blk entry;
            break :blk &.{};
        } else &.{};

        const exc_count = self.exceptionSeedCount(block_id, block);
        if (seed.len > 0) {
            for (seed) |val| {
                const cloned = try sim.cloneStackValue(val);
                try sim.stack.push(cloned);
            }
        }
        if (exc_count > 0) {
            sim.lenient = true;
            sim.stack.allow_underflow = true;
            for (0..exc_count) |_| {
                const placeholder = try a.create(Expr);
                placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                try sim.stack.push(.{ .expr = placeholder });
            }
        }

        // FOR_LOOP header needs [seq, idx] on stack from setup predecessor
        const term = block.terminator();
        if (seed.len == 0 and term != null and term.?.opcode == .FOR_LOOP) {
            // Find setup predecessor (not the loop back edge)
            for (block.predecessors) |pred_id| {
                if (pred_id < block_id) { // Setup comes before header
                    const pred = &self.cfg.blocks[pred_id];
                    for (pred.instructions) |inst| {
                        try sim.simulate(inst);
                    }
                    break;
                }
            }
        }

        if (seed.len == 0 and skip_first_store.*) {
            // Loop target consumes the iteration value from the stack.
            try sim.stack.push(.unknown);
        }
        if (seed.len == 0 and seed_pop.*) {
            // Legacy JUMP_IF_* leaves the condition on stack for a leading POP_TOP.
            try sim.stack.push(.unknown);
            seed_pop.* = false;
        }
        if (self.pending_ternary_expr) |expr| {
            try sim.stack.push(.{ .expr = expr });
            self.pending_ternary_expr = null;
        }

        if (sim.stack.len() == 0 and self.needsPredecessorSeed(block)) {
            var cur_id = block.id;
            var to_simulate: [16]u32 = undefined;
            var sim_count: usize = 0;
            while (sim_count < 16) {
                var found_pred: ?u32 = null;
                const cur_block = &self.cfg.blocks[cur_id];
                for (cur_block.predecessors) |pred_id| {
                    if (pred_id < cur_id) {
                        found_pred = pred_id;
                        break;
                    }
                }
                if (found_pred) |pid| {
                    to_simulate[sim_count] = pid;
                    sim_count += 1;
                    cur_id = pid;
                } else break;
            }
            var i: usize = sim_count;
            while (i > 0) {
                i -= 1;
                const pred = &self.cfg.blocks[to_simulate[i]];
                for (pred.instructions) |inst| {
                    try sim.simulate(inst);
                }
            }
        }

        if (sim.stack.len() == 0) {
            sim.lenient = true;
            sim.stack.allow_underflow = true;
        }

        var skip_store_count: u32 = 0;
        const instructions = block.instructions;
        var idx: usize = 0;
        if (skip_first > 0) {
            const limit = @min(skip_first, instructions.len);
            while (idx < limit) : (idx += 1) {
                const inst = instructions[idx];
                errdefer if (self.last_error_ctx == null) {
                    self.last_error_ctx = .{
                        .code_name = self.code.name,
                        .block_id = block_id,
                        .offset = inst.offset,
                        .opcode = inst.opcode.name(),
                    };
                };
                try sim.simulate(inst);
            }
        }
        while (idx < instructions.len) : (idx += 1) {
            const inst = instructions[idx];
            errdefer if (self.last_error_ctx == null) {
                self.last_error_ctx = .{
                    .code_name = self.code.name,
                    .block_id = block_id,
                    .offset = inst.offset,
                    .opcode = inst.opcode.name(),
                };
            };
            if (inst.opcode == .IMPORT_NAME) {
                if (try self.tryDecompileImportFromGroup(&sim, instructions, idx, stmts, a)) |end_idx| {
                    idx = end_idx;
                    continue;
                }
            }
            if (returnCleanupSkip(instructions, idx)) |skip| {
                idx += skip - 1;
                continue;
            }
            if (loop_header) |header_id| {
                if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                    if (block.terminator()) |blk_term| {
                        if (blk_term.offset == inst.offset) {
                            const trace_on = self.trace_loop_guards and self.trace_file != null;
                            if (try self.guardBranchToHeader(block, inst, header_id, trace_on)) |branch| {
                                const cond = try sim.stack.popExpr();
                                const guard_cond = try self.guardCondForBranch(cond, inst.opcode, branch.taken);
                                if (trace_on) {
                                    const insert_idx = stmts.items.len;
                                    try self.emitGuardTrace(
                                        block_id,
                                        header_id,
                                        inst,
                                        branch.target,
                                        guard_cond,
                                        insert_idx,
                                        branch.path,
                                    );
                                }
                                const cont = try self.makeContinue();
                                const body = try a.alloc(*Stmt, 1);
                                body[0] = cont;
                                const guard_stmt = try a.create(Stmt);
                                guard_stmt.* = .{ .if_stmt = .{
                                    .condition = guard_cond,
                                    .body = body,
                                    .else_body = &.{},
                                } };
                                try stmts.append(a, guard_stmt);
                                return;
                            }
                        }
                    }
                }
            }
            switch (inst.opcode) {
                .UNPACK_SEQUENCE, .UNPACK_EX => {
                    const count = if (inst.opcode == .UNPACK_EX) blk: {
                        const before = inst.arg & 0xFF;
                        const after = (inst.arg >> 8) & 0xFF;
                        break :blk before + 1 + after;
                    } else inst.arg;
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
                    const skip_count = try self.handleUnpack(&sim, instructions, idx, stmts, a);
                    if (skip_count > 0) {
                        idx += skip_count;
                        continue;
                    }
                    continue;
                },
                .STORE_FAST, .STORE_NAME, .STORE_GLOBAL, .STORE_DEREF => {
                    if (skip_store_count > 0) {
                        skip_store_count -= 1;
                        const val = sim.stack.pop() orelse StackValue.unknown;
                        val.deinit(sim.allocator, sim.stack_alloc);
                        continue;
                    }
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        const val = sim.stack.pop() orelse StackValue.unknown;
                        val.deinit(sim.allocator, sim.stack_alloc);
                        continue;
                    }
                    const name = switch (inst.opcode) {
                        .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                        .STORE_DEREF => sim.getDeref(inst.arg) orelse "<unknown>",
                        else => sim.getName(inst.arg) orelse "<unknown>",
                    };
                    const value = sim.stack.pop() orelse StackValue.unknown;
                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(a, stmt);
                    }
                },
                .STORE_SUBSCR => {
                    try self.emitStoreSubscr(&sim, stmts, a);
                },
                .STORE_SLICE => {
                    try self.emitStoreSlice(&sim, stmts, a);
                },
                .STORE_ATTR => {
                    try self.emitStoreAttr(&sim, instructions, &idx, stmts, a, skip_first, null);
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
                    try self.handlePopTopStmt(&sim, block, stmts, a);
                },
                .RAISE_VARARGS, .DELETE_NAME, .DELETE_FAST, .DELETE_GLOBAL, .DELETE_DEREF, .DELETE_ATTR, .DELETE_SUBSCR => {
                    if (try self.tryEmitStatement(inst, &sim)) |stmt| {
                        try stmts.append(a, stmt);
                    }
                },
                .WITH_EXCEPT_START, .WITH_CLEANUP_START, .WITH_CLEANUP_FINISH, .WITH_CLEANUP => {
                    continue;
                },
                else => {
                    try sim.simulate(inst);
                },
            }
        }
    }

    fn handlePopTopStmt(
        self: *Decompiler,
        sim: *SimContext,
        block: *const cfg_mod.BasicBlock,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
    ) DecompileError!void {
        if (sim.stack.len() == 0) {
            return;
        }
        if (block.instructions.len == 2) {
            const first = block.instructions[0];
            const second = block.instructions[1];
            if (first.opcode == .POP_TOP and second.isUnconditionalJump()) {
                const cleanup = sim.stack.pop().?;
                var val = cleanup;
                val.deinit(sim.allocator, sim.stack_alloc);
                return;
            }
        }
        const val = sim.stack.pop().?;
        switch (val) {
            .expr => |e| {
                if (self.makeExprStmt(e)) |stmt| {
                    try stmts.append(stmts_allocator, stmt);
                } else |err| {
                    if (err != error.SkipStatement) return err;
                }
            },
            else => {
                // Discard non-expression values (e.g., intermediate stack values)
                val.deinit(sim.allocator, sim.stack_alloc);
            },
        }
    }

    /// Process part of a block (before control flow instruction).
    fn processPartialBlock(
        self: *Decompiler,
        block: *const cfg_mod.BasicBlock,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
        skip_first_store: *bool,
        stop_idx: ?usize,
    ) DecompileError!void {
        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        sim.lenient = true;
        sim.stack.allow_underflow = true;
        defer sim.deinit();

        if (block.id < self.stack_in.len) {
            if (self.stack_in[block.id]) |entry| {
                for (entry) |val| {
                    const cloned = try sim.cloneStackValue(val);
                    try sim.stack.push(cloned);
                }
            }
        }
        if (sim.stack.len() == 0 and self.needsPredecessorSeed(block)) {
            var cur_id = block.id;
            var to_simulate: [16]u32 = undefined;
            var sim_count: usize = 0;
            while (sim_count < 16) {
                var found_pred: ?u32 = null;
                const cur_block = &self.cfg.blocks[cur_id];
                for (cur_block.predecessors) |pred_id| {
                    if (pred_id < cur_id) {
                        found_pred = pred_id;
                        break;
                    }
                }
                if (found_pred) |pid| {
                    to_simulate[sim_count] = pid;
                    sim_count += 1;
                    cur_id = pid;
                } else break;
            }
            var i: usize = sim_count;
            while (i > 0) {
                i -= 1;
                const pred = &self.cfg.blocks[to_simulate[i]];
                for (pred.instructions) |inst| {
                    try sim.simulate(inst);
                }
            }
        }
        if (self.pending_store_expr) |expr| {
            try sim.stack.push(.{ .expr = expr });
            self.pending_store_expr = null;
        }
        if (self.pending_ternary_expr) |expr| {
            try sim.stack.push(.{ .expr = expr });
            self.pending_ternary_expr = null;
        }

        const instructions = block.instructions;
        var idx: usize = 0;
        var skip_store_count: u32 = 0;
        while (idx < instructions.len) : (idx += 1) {
            if (stop_idx) |limit| {
                if (idx >= limit) break;
            }
            const inst = instructions[idx];
            // Stop at control flow instructions
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (inst.opcode == .JUMP_BACKWARD or inst.opcode == .JUMP_BACKWARD_NO_INTERRUPT) break;

            if (inst.opcode == .IMPORT_NAME) {
                if (try self.tryDecompileImportFromGroup(&sim, instructions, idx, stmts, stmts_allocator)) |end_idx| {
                    idx = end_idx;
                    continue;
                }
            }
            switch (inst.opcode) {
                .UNPACK_SEQUENCE, .UNPACK_EX => {
                    const count = if (inst.opcode == .UNPACK_EX) blk: {
                        const before = inst.arg & 0xFF;
                        const after = (inst.arg >> 8) & 0xFF;
                        break :blk before + 1 + after;
                    } else inst.arg;
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        if (count == 0) {
                            _ = sim.stack.pop();
                            continue;
                        }
                        skip_store_count = count;
                        try sim.simulate(inst);
                        continue;
                    }
                    const skip_count = try self.handleUnpack(&sim, instructions, idx, stmts, stmts_allocator);
                    if (skip_count > 0) {
                        idx += skip_count;
                        continue;
                    }
                },
                .STORE_FAST, .STORE_NAME, .STORE_GLOBAL, .STORE_DEREF => {
                    if (skip_store_count > 0) {
                        skip_store_count -= 1;
                        const val = sim.stack.pop() orelse StackValue.unknown;
                        val.deinit(sim.allocator, sim.stack_alloc);
                        continue;
                    }
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        continue;
                    }
                    const name = switch (inst.opcode) {
                        .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                        .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                        .STORE_DEREF => sim.getDeref(inst.arg) orelse "<unknown>",
                        else => "<unknown>",
                    };
                    const value = sim.stack.pop() orelse blk: {
                        if (sim.lenient or sim.stack.allow_underflow) break :blk StackValue.unknown;
                        return error.StackUnderflow;
                    };
                    if (try self.handleStoreValue(name, value)) |stmt| {
                        try stmts.append(stmts_allocator, stmt);
                    }
                },
                .STORE_ATTR => {
                    try self.emitStoreAttr(&sim, instructions, &idx, stmts, stmts_allocator, 0, stop_idx);
                },
                .STORE_SUBSCR => {
                    try self.emitStoreSubscr(&sim, stmts, stmts_allocator);
                },
                .STORE_SLICE => {
                    try self.emitStoreSlice(&sim, stmts, stmts_allocator);
                },
                .POP_TOP => {
                    try self.handlePopTopStmt(&sim, block, stmts, stmts_allocator);
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
                if (ctrl.Analyzer.isConditionalJump(undefined, term.opcode)) return true;
            }
        }
        // Check if predecessor is a for loop header (FOR_ITER terminator)
        for (block.predecessors) |pred_id| {
            if (pred_id >= self.cfg.blocks.len) continue;
            const pred = &self.cfg.blocks[pred_id];
            const term = pred.terminator() orelse continue;
            if (term.opcode == .FOR_ITER) return true;
        }
        // Check if this is an exception handler
        if (block.is_exception_handler) return true;
        return false;
    }

    const LoopIfParts = struct {
        condition: *Expr,
        then_body: []const *Stmt,
        else_body: []const *Stmt,
        else_is_continuation: bool,
        then_leads: bool,
        else_leads: bool,
        cond_op: Opcode,
        then_block: u32,
        else_block: ?u32,
    };

    fn condExprFromBlock(
        self: *Decompiler,
        block_id: u32,
        sim: *SimContext,
        then_block: u32,
        else_block: ?u32,
        skip_first: usize,
    ) DecompileError!?*Expr {
        if (block_id >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[block_id];

        var conds: [2]*Expr = undefined;
        var jumps: [2]Opcode = undefined;
        var targets: [2]?u32 = .{ null, null };
        var cond_count: usize = 0;

        const instructions = block.instructions;
        var idx: usize = if (skip_first > instructions.len) instructions.len else skip_first;
        while (idx < instructions.len) : (idx += 1) {
            const inst = instructions[idx];
            if (inst.opcode == .NOT_TAKEN or inst.opcode == .CACHE) continue;
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) {
                const cond = try sim.stack.popExpr();
                if (cond_count < conds.len) {
                    conds[cond_count] = cond;
                    jumps[cond_count] = inst.opcode;
                    if (inst.jumpTarget(self.cfg.version)) |target_off| {
                        targets[cond_count] = self.cfg.blockAtOffset(target_off);
                    }
                    cond_count += 1;
                }
                if (cond_count >= 2) break;
                continue;
            }
            try sim.simulate(inst);
        }

        if (cond_count == 0) return null;
        if (cond_count == 1) return conds[0];

        if (else_block) |else_id| {
            if (targets[0] != null and targets[1] != null) {
                const t0 = targets[0].?;
                const t1 = targets[1].?;
                if (t0 == then_block and t1 == else_id and
                    self.isTrueJump(jumps[0]) and self.isFalseJump(jumps[1]))
                {
                    return try self.makeBoolPair(conds[0], conds[1], .or_);
                }
                if (t0 == else_id and t1 == else_id and
                    self.isFalseJump(jumps[0]) and self.isFalseJump(jumps[1]))
                {
                    return try self.makeBoolPair(conds[0], conds[1], .and_);
                }
            }
        }

        return conds[0];
    }

    const LoopCond = struct {
        expr: *Expr,
        base_vals: []StackValue,
    };

    fn loopCondExpr(
        self: *Decompiler,
        block_id: u32,
        then_block: u32,
        else_block: ?u32,
        skip_first: usize,
    ) DecompileError!?LoopCond {
        if (block_id >= self.cfg.blocks.len) return null;
        const cond_block = &self.cfg.blocks[block_id];

        var sim = self.initSim(self.arena.allocator(), self.arena.allocator(), self.code, self.version);
        defer sim.deinit();
        sim.lenient = true;
        sim.stack.allow_underflow = true;

        if (block_id < self.stack_in.len) {
            if (self.stack_in[block_id]) |entry| {
                for (entry) |val| {
                    const cloned = try sim.cloneStackValue(val);
                    try sim.stack.push(cloned);
                }
            }
        }
        const exc_count = self.exceptionSeedCount(block_id, cond_block);
        if (exc_count > 0) {
            for (0..exc_count) |_| {
                const placeholder = try self.arena.allocator().create(Expr);
                placeholder.* = .{ .name = .{ .id = "__exception__", .ctx = .load } };
                try sim.stack.push(.{ .expr = placeholder });
            }
        }
        if (sim.stack.len() == 0 and self.needsPredecessorSeed(cond_block)) {
            try self.seedFromPredecessors(block_id, &sim);
        }

        const expr = (try self.condExprFromBlock(block_id, &sim, then_block, else_block, skip_first)) orelse return null;
        const base_vals = try self.cloneStackValues(sim.stack.items.items);
        return .{ .expr = expr, .base_vals = base_vals };
    }

    fn decompileLoopExitBranch(
        self: *Decompiler,
        block_id: u32,
        end_block: ?u32,
        seed_pop: bool,
    ) DecompileError![]const *Stmt {
        _ = end_block;
        const skip: usize = if (seed_pop) 1 else 0;
        if (self.jumpTargetIfJumpOnly(block_id, true) != null) {
            try self.consumed.set(self.allocator, block_id);
            return &[_]*Stmt{};
        }
        const body = try self.decompileBlockRangeWithStackAndSkip(block_id, block_id + 1, &.{}, skip);
        try self.consumed.set(self.allocator, block_id);
        return body;
    }

    fn loopIfParts(
        self: *Decompiler,
        pattern: ctrl.IfPattern,
        loop_header: u32,
        visited: *std.DynamicBitSet,
    ) DecompileError!?LoopIfParts {
        if (self.if_in_progress) |*set| {
            if (set.isSet(pattern.condition_block)) return null;
            set.set(pattern.condition_block);
            defer set.unset(pattern.condition_block);
        }
        const cond_block = &self.cfg.blocks[pattern.condition_block];
        const term = cond_block.terminator() orelse return null;
        var cond_op = term.opcode;
        const legacy_cond = cond_op == .JUMP_IF_FALSE or cond_op == .JUMP_IF_TRUE;

        var last_stmt_idx: ?usize = null;
        for (cond_block.instructions, 0..) |inst, idx| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (inst.opcode == .JUMP_BACKWARD or inst.opcode == .JUMP_BACKWARD_NO_INTERRUPT) break;
            switch (inst.opcode) {
                .STORE_FAST,
                .STORE_NAME,
                .STORE_GLOBAL,
                .STORE_DEREF,
                .STORE_ATTR,
                .STORE_SUBSCR,
                .POP_TOP,
                .DELETE_NAME,
                .DELETE_FAST,
                .DELETE_GLOBAL,
                .DELETE_DEREF,
                .DELETE_ATTR,
                .DELETE_SUBSCR,
                .RETURN_VALUE,
                .RETURN_CONST,
                .RAISE_VARARGS,
                => last_stmt_idx = idx + 1,
                else => {},
            }
        }
        const skip_cond = last_stmt_idx orelse 0;

        const cond_res = (try self.loopCondExpr(
            pattern.condition_block,
            pattern.then_block,
            pattern.else_block,
            skip_cond,
        )) orelse return null;
        var condition = cond_res.expr;
        const base_vals = cond_res.base_vals;
        defer deinitStackValuesSlice(self.allocator, self.allocator, base_vals);
        var then_block = pattern.then_block;
        var else_block = pattern.else_block;
        var is_elif = pattern.is_elif;

        if (is_elif) {
            if (else_block) |else_id| {
                const else_pat = try self.analyzer.detectPattern(else_id);
                if (else_pat == .if_stmt) {
                    const elif_pat = else_pat.if_stmt;
                    if (elif_pat.then_block == then_block and elif_pat.else_block != null and
                        self.resolveJumpOnlyBlock(elif_pat.else_block.?) == loop_header)
                    {
                        const elif_block = &self.cfg.blocks[elif_pat.condition_block];
                        var elif_last: ?usize = null;
                        for (elif_block.instructions, 0..) |inst, idx| {
                            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
                            if (inst.opcode == .JUMP_BACKWARD or inst.opcode == .JUMP_BACKWARD_NO_INTERRUPT) break;
                            switch (inst.opcode) {
                                .STORE_FAST,
                                .STORE_NAME,
                                .STORE_GLOBAL,
                                .STORE_DEREF,
                                .STORE_ATTR,
                                .STORE_SUBSCR,
                                .POP_TOP,
                                .DELETE_NAME,
                                .DELETE_FAST,
                                .DELETE_GLOBAL,
                                .DELETE_DEREF,
                                .DELETE_ATTR,
                                .DELETE_SUBSCR,
                                .RETURN_VALUE,
                                .RETURN_CONST,
                                .RAISE_VARARGS,
                                => elif_last = idx + 1,
                                else => {},
                            }
                        }
                        const elif_skip = elif_last orelse 0;
                        if (try self.loopCondExpr(elif_pat.condition_block, elif_pat.then_block, elif_pat.else_block, elif_skip)) |elif_res| {
                            defer deinitStackValuesSlice(self.allocator, self.allocator, elif_res.base_vals);
                            condition = try self.makeBoolPair(condition, elif_res.expr, .or_);
                            if (self.cfg.blocks[elif_pat.condition_block].terminator()) |elif_term| {
                                cond_op = elif_term.opcode;
                            }
                            visited.set(else_id);
                            else_block = elif_pat.else_block;
                            is_elif = false;
                        }
                    }
                }
            }
        }

        if (!is_elif) {
            if (else_block) |else_id| {
                var seen = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
                defer seen.deinit();
                const else_res = self.resolveJumpOnlyBlock(else_id);
                var cur = then_block;
                var final_then = then_block;
                var progressed = false;
                while (cur < self.cfg.blocks.len) {
                    if (seen.isSet(cur)) break;
                    seen.set(cur);
                    const blk = &self.cfg.blocks[cur];
                    const blk_term = blk.terminator() orelse break;
                    if (!ctrl.Analyzer.isConditionalJump(undefined, blk_term.opcode)) break;
                    if (condBlockHasPrelude(blk)) break;
                    var t_id: ?u32 = null;
                    var f_id: ?u32 = null;
                    for (blk.successors) |edge| {
                        if (edge.edge_type == .exception) continue;
                        if (edge.edge_type == .conditional_false) {
                            f_id = edge.target;
                        } else if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                            t_id = edge.target;
                        }
                    }
                    if (t_id == null or f_id == null) break;
                    if (self.resolveJumpOnlyBlock(f_id.?) != else_res) break;
                    if (t_id.? == else_id) break;
                    progressed = true;
                    final_then = self.resolveJumpOnlyBlock(t_id.?);
                    cur = t_id.?;
                }
                if (progressed and final_then != then_block) {
                    var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
                    defer in_stack.deinit();
                    var memo: std.AutoHashMapUnmanaged(u32, *Expr) = .{};
                    defer memo.deinit(self.allocator);
                    if (try self.buildCondTree(
                        pattern.condition_block,
                        pattern.condition_block,
                        condition,
                        final_then,
                        else_id,
                        base_vals,
                        null,
                        null,
                        &in_stack,
                        &memo,
                    )) |expr| {
                        condition = expr;
                        then_block = final_then;
                    }
                }
            }
        }

        var cond_tree_applied = false;
        if (!is_elif) {
            if (else_block) |else_id| {
                if (else_id < self.cfg.blocks.len) {
                    const else_blk = &self.cfg.blocks[else_id];
                    if (else_blk.terminator()) |else_term| {
                        if (ctrl.Analyzer.isConditionalJump(undefined, else_term.opcode)) {
                            if (try self.condChainFalseTarget(else_id, then_block)) |fb| {
                                var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
                                defer in_stack.deinit();
                                var memo: std.AutoHashMapUnmanaged(u32, *Expr) = .{};
                                defer memo.deinit(self.allocator);
                                if (try self.buildCondTree(
                                    pattern.condition_block,
                                    pattern.condition_block,
                                    condition,
                                    then_block,
                                    fb,
                                    base_vals,
                                    null,
                                    null,
                                    &in_stack,
                                    &memo,
                                )) |expr| {
                                    condition = expr;
                                    else_block = fb;
                                    cond_tree_applied = true;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (!cond_tree_applied and self.isTrueJump(cond_op) and else_block != null) {
            const else_res = self.resolveJumpOnlyBlock(else_block.?);
            const else_cont = else_res == loop_header or self.loopBlockLeadsToContinue(else_block.?, loop_header);
            if (!else_cont) {
                condition = try self.invertConditionExpr(condition);
                try self.emitDecisionTrace(pattern.condition_block, "loop_if_invert_true_jump", condition);
                const tmp = then_block;
                then_block = else_block.?;
                else_block = tmp;
                is_elif = false;
                cond_op = self.invertJumpOpcode(cond_op);
            }
        }

        const then_res = self.resolveJumpOnlyBlock(then_block);
        const else_res = if (else_block) |else_id| self.resolveJumpOnlyBlock(else_id) else null;
        var then_to_header = then_res == loop_header or self.loopBlockLeadsToContinue(then_block, loop_header);
        var else_to_header = false;
        if (else_block) |else_id| {
            if (else_res) |res| {
                if (res == loop_header) else_to_header = true;
            }
            if (!else_to_header and self.loopBlockLeadsToContinue(else_id, loop_header)) {
                else_to_header = true;
            }
        }

        const then_is_continue = then_res == loop_header;
        const then_empty = then_is_continue or self.blockIsCleanupOnly(&self.cfg.blocks[then_block]);
        const else_has_body = else_res != null and else_res.? != loop_header;
        if (then_to_header and then_empty and else_block != null and (!else_to_header or (then_is_continue and else_has_body))) {
            condition = try self.invertConditionExpr(condition);
            try self.emitDecisionTrace(pattern.condition_block, "loop_if_invert_then_to_header", condition);
            then_block = else_block.?;
            else_block = null;
            is_elif = false;
            then_to_header = false;
            else_to_header = true;
        }

        if (then_to_header and else_block == null) return null;

        const then_in_loop = self.analyzer.inLoop(then_block, loop_header);
        const else_in_loop = if (else_block) |else_id|
            self.analyzer.inLoop(else_id, loop_header)
        else
            false;
        const merge_in_loop = if (pattern.merge_block) |merge_id|
            self.analyzer.inLoop(merge_id, loop_header)
        else
            false;
        var else_is_continuation = else_to_header or (else_in_loop and !merge_in_loop and !then_in_loop);
        var else_is_fallthrough = false;
        if (!else_is_continuation) {
            if (else_block) |else_id| {
                if (self.hasSingleNormalSuccessor(then_block, else_id)) {
                    else_is_continuation = true;
                    else_is_fallthrough = true;
                }
            }
        }

        // Decompile the then body
        var skip_first = false;
        const then_block_ptr = &self.cfg.blocks[then_block];
        var seed_then = legacy_cond and then_block_ptr.instructions.len > 0 and then_block_ptr.instructions[0].opcode == .POP_TOP;
        var body_stop: ?u32 = null;
        if (else_block) |else_id| {
            if (else_id > then_block) {
                body_stop = else_id;
            } else if (else_is_continuation) {
                body_stop = else_id;
            }
        }
        if (merge_in_loop) {
            if (pattern.merge_block) |merge_id| {
                if (merge_id > then_block and (body_stop == null or merge_id < body_stop.?)) {
                    body_stop = merge_id;
                }
            }
        }
        const then_break_tgt = self.loopBreakTarget(then_block, loop_header);
        const then_exit = then_break_tgt != null or self.isTerminalBlock(then_block);
        const a = self.arena.allocator();
        var then_body = if (!then_in_loop and then_exit) blk: {
            var end = body_stop;
            if (then_break_tgt) |tgt| {
                if (end == null or tgt < end.?) end = tgt;
            }
            const body = try self.decompileLoopExitBranch(then_block, end, seed_then);
            break :blk body;
        } else try self.decompileLoopBody(
            then_block,
            loop_header,
            &skip_first,
            &seed_then,
            visited,
            body_stop,
            0,
            false,
        );
        // Decompile the else body if present
        var else_body = if (else_block) |else_id| blk: {
            var skip = false;
            const else_block_ptr = &self.cfg.blocks[else_id];
            var seed_else = legacy_cond and else_block_ptr.instructions.len > 0 and else_block_ptr.instructions[0].opcode == .POP_TOP;
            const else_break_tgt = self.loopBreakTarget(else_id, loop_header);
            const else_exit = else_break_tgt != null or self.isTerminalBlock(else_id);
            const else_stop = if (merge_in_loop and pattern.merge_block != null and pattern.merge_block.? != else_id)
                pattern.merge_block
            else
                null;
            if (!else_in_loop and else_exit) {
                var end = else_stop;
                if (else_break_tgt) |tgt| {
                    if (end == null or tgt < end.?) end = tgt;
                }
                break :blk try self.decompileLoopExitBranch(else_id, end, seed_else);
            }
            if (else_is_continuation) {
                if (else_is_fallthrough) break :blk &[_]*Stmt{};
                if (self.resolveJumpOnlyBlock(else_id) == loop_header) {
                    break :blk &[_]*Stmt{};
                }
                if (else_in_loop) {
                    break :blk try self.decompileLoopBody(
                        else_id,
                        loop_header,
                        &skip,
                        &seed_else,
                        visited,
                        else_stop,
                        0,
                        false,
                    );
                }
                const else_end = try self.branchEnd(else_id, null);
                break :blk try self.decompileBranchRange(else_id, else_end, &.{}, 0);
            }
            if (is_elif) {
                const else_pattern = try self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    const elif_stmt = try self.decompileLoopIf(else_pattern.if_stmt, loop_header, visited);
                    if (elif_stmt) |s| {
                        const body = try a.alloc(*Stmt, 1);
                        body[0] = s;
                        break :blk body;
                    }
                }
            }
            break :blk try self.decompileLoopBody(
                else_id,
                loop_header,
                &skip,
                &seed_else,
                visited,
                else_stop,
                0,
                false,
            );
        } else &[_]*Stmt{};
        if (self.loopBlockLeadsToBreak(then_block, loop_header)) {
            if (then_body.len == 0 or !self.bodyEndsTerminal(then_body)) {
                const br = try self.makeBreak();
                const body = try a.alloc(*Stmt, then_body.len + 1);
                if (then_body.len > 0) {
                    std.mem.copyForwards(*Stmt, body[0..then_body.len], then_body);
                }
                body[then_body.len] = br;
                then_body = body;
            }
        }
        if (else_block != null and self.loopBlockLeadsToBreak(else_block.?, loop_header)) {
            if (else_body.len == 0 or !self.bodyEndsTerminal(else_body)) {
                const br = try self.makeBreak();
                const body = try a.alloc(*Stmt, else_body.len + 1);
                if (else_body.len > 0) {
                    std.mem.copyForwards(*Stmt, body[0..else_body.len], else_body);
                }
                body[else_body.len] = br;
                else_body = body;
            }
        }
        const then_leads = self.resolveJumpOnlyBlock(then_block) == loop_header or
            self.blockLeadsToHeader(then_block, loop_header);
        var else_leads = false;
        if (else_block) |else_id| {
            const else_res2 = self.resolveJumpOnlyBlock(else_id);
            else_leads = else_res2 == loop_header or self.blockLeadsToHeader(else_id, loop_header);
        }
        if (then_leads and else_block != null and !else_leads) {
            if (then_body.len == 0 or !self.bodyEndsTerminal(then_body)) {
                const cont = try self.makeContinue();
                const body = try a.alloc(*Stmt, then_body.len + 1);
                if (then_body.len > 0) {
                    std.mem.copyForwards(*Stmt, body[0..then_body.len], then_body);
                }
                body[then_body.len] = cont;
                then_body = body;
            }
        }
        if (else_leads and !then_leads and else_body.len > 0 and then_body.len == 0) {
            if (!self.bodyEndsTerminal(else_body)) {
                const cont = try self.makeContinue();
                const body = try a.alloc(*Stmt, else_body.len + 1);
                std.mem.copyForwards(*Stmt, body[0..else_body.len], else_body);
                body[else_body.len] = cont;
                else_body = body;
            }
        }

        return .{
            .condition = condition,
            .then_body = then_body,
            .else_body = else_body,
            .else_is_continuation = else_is_continuation,
            .then_leads = then_leads,
            .else_leads = else_leads,
            .cond_op = cond_op,
            .then_block = then_block,
            .else_block = else_block,
        };
    }

    /// Decompile an if statement that's inside a loop.
    fn decompileLoopIf(
        self: *Decompiler,
        pattern: ctrl.IfPattern,
        loop_header: u32,
        visited: *std.DynamicBitSet,
    ) DecompileError!?*Stmt {
        const parts = try self.loopIfParts(pattern, loop_header, visited) orelse return null;
        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .{ .if_stmt = .{
            .condition = parts.condition,
            .body = parts.then_body,
            .else_body = parts.else_body,
        } };

        return stmt;
    }

    fn tryNeedsBreak(self: *Decompiler, pattern: *const ctrl.TryPattern, loop_header: u32) bool {
        if (pattern.try_block >= self.cfg.blocks.len) return false;
        const try_block = &self.cfg.blocks[pattern.try_block];
        var normal_target: ?u32 = null;
        for (try_block.successors) |edge| {
            if (edge.edge_type == .normal) {
                normal_target = edge.target;
                break;
            }
        }
        if (normal_target) |target_id| {
            const exit = self.analyzer.detectLoopExit(target_id, &[_]u32{loop_header});
            if (exit != .break_stmt) return false;
        } else {
            return false;
        }
        for (pattern.handlers) |handler| {
            if (handler.handler_block >= self.cfg.blocks.len) continue;
            if (self.analyzer.inLoop(handler.handler_block, loop_header)) return true;
        }
        return false;
    }

    fn appendTryBreak(self: *Decompiler, stmt: *Stmt) DecompileError!void {
        if (stmt.* != .try_stmt) return;
        const else_body = stmt.try_stmt.else_body;
        if (else_body.len > 0) {
            switch (else_body[else_body.len - 1].*) {
                .break_stmt, .return_stmt, .raise_stmt, .continue_stmt => return,
                else => {},
            }
        }
        const a = self.arena.allocator();
        const br = try self.makeBreak();
        const new_body = try a.alloc(*Stmt, else_body.len + 1);
        if (else_body.len > 0) {
            std.mem.copyForwards(*Stmt, new_body[0..else_body.len], else_body);
        }
        new_body[else_body.len] = br;
        stmt.try_stmt.else_body = new_body;

        if (stmt.try_stmt.handlers.len > 0) {
            const handlers = stmt.try_stmt.handlers;
            var replaced = false;
            const next_handlers = try a.alloc(ast.ExceptHandler, handlers.len);
            for (handlers, 0..) |h, idx| {
                next_handlers[idx] = h;
                if (h.body.len == 0) {
                    const cont = try self.makeContinue();
                    const body = try a.alloc(*Stmt, 1);
                    body[0] = cont;
                    next_handlers[idx].body = body;
                    replaced = true;
                }
            }
            if (replaced) {
                stmt.try_stmt.handlers = next_handlers;
            }
        }
    }

    fn nextLoopBlockAfterIf(
        self: *Decompiler,
        pattern: ctrl.IfPattern,
        loop_header: u32,
        cur_block: u32,
        stop_block: ?u32,
    ) DecompileError!?u32 {
        if (pattern.merge_block) |merge_id| {
            if (stop_block) |stop_id| {
                if (merge_id == stop_id) return null;
            }
            if (merge_id == loop_header) return null;
            if (!self.analyzer.inLoop(merge_id, loop_header)) return null;
            return merge_id;
        }

        var next_id = try self.findIfChainEnd(pattern);
        if (self.if_next) |next| {
            next_id = next;
            self.if_next = null;
            self.chained_cmp_next_block = null;
        } else if (self.chained_cmp_next_block) |chain_next| {
            next_id = chain_next;
            self.chained_cmp_next_block = null;
        }
        if (stop_block) |stop_id| {
            if (next_id == stop_id) return null;
        }
        if (next_id == loop_header) return null;
        if (!self.analyzer.inLoop(next_id, loop_header)) return null;
        if (next_id <= cur_block) return null;
        return next_id;
    }

    /// Decompile a body within a loop using loop-region membership.
    fn decompileLoopBody(
        self: *Decompiler,
        start_block: u32,
        loop_header: u32,
        skip_first_store: *bool,
        seed_pop: *bool,
        visited: *std.DynamicBitSet,
        stop_block: ?u32,
        skip_first: usize,
        ignore_header_while: bool,
    ) DecompileError![]const *Stmt {
        const a = self.arena.allocator();
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(a);

        var block_idx = start_block;
        var loop_end_offset: ?u32 = null;
        const start_offset: u32 = if (start_block < self.cfg.blocks.len)
            self.cfg.blocks[start_block].start_offset
        else
            0;
        const stop_offset: ?u32 = if (stop_block) |stop_id| blk: {
            if (stop_id < self.cfg.blocks.len) break :blk self.cfg.blocks[stop_id].start_offset;
            break :blk null;
        } else null;
        if (loop_header < self.cfg.blocks.len) {
            const header = &self.cfg.blocks[loop_header];
            for (header.successors) |edge| {
                if (edge.edge_type == .conditional_false and edge.target < self.cfg.blocks.len) {
                    if (!self.analyzer.inLoop(edge.target, loop_header)) {
                        const end_off = self.cfg.blocks[edge.target].start_offset;
                        if (end_off > start_offset) {
                            loop_end_offset = end_off;
                            break;
                        }
                    }
                }
            }
        }

        while (block_idx < self.cfg.blocks.len) {
            const block = &self.cfg.blocks[block_idx];
            if (stop_block) |stop_id| {
                if (block_idx == stop_id) break;
            }
            if (stop_offset) |stop_off| {
                if (stop_off > start_offset and block.start_offset >= stop_off) break;
            }
            if (loop_end_offset) |end_off| {
                if (block.start_offset >= end_off) break;
            }
            if (self.consumed.isSet(block_idx)) {
                block_idx += 1;
                continue;
            }
            if (!self.analyzer.inLoop(block_idx, loop_header)) {
                block_idx += 1;
                continue;
            }
            if (block_idx == loop_header and block_idx != start_block) break;
            if (visited.isSet(block_idx)) {
                block_idx += 1;
                continue;
            }
            visited.set(block_idx);

            const has_back_edge = self.hasLoopBackEdge(block, loop_header);
            var pattern = try self.analyzer.detectPatternInLoop(block_idx);
            if (block_idx == start_block and pattern == .while_loop and pattern.while_loop.header_block == loop_header) {
                if (skip_first > 0 or ignore_header_while) {
                    pattern = .unknown;
                }
            }
            if (pattern == .unknown and !block.is_exception_handler and self.analyzer.hasExceptionEdge(block)) {
                if (try self.analyzer.detectTryPatternAt(block_idx)) |tp| {
                    pattern = .{ .try_stmt = tp };
                }
            }

            switch (pattern) {
                .if_stmt => |p| {
                    try self.processPartialBlock(block, &stmts, a, skip_first_store, null);

                    const parts = try self.loopIfParts(p, loop_header, visited) orelse {
                        block_idx += 1;
                        continue;
                    };

                    const else_cont = if (parts.else_is_continuation and parts.else_block != null) blk: {
                        const else_id = parts.else_block.?;
                        if (self.resolveJumpOnlyBlock(else_id) == loop_header or
                            self.loopBlockLeadsToContinue(else_id, loop_header) or
                            self.blockLeadsToHeader(else_id, loop_header))
                        {
                            break :blk true;
                        }
                        break :blk false;
                    } else false;
                    const then_guard = parts.then_leads and parts.else_block != null and !parts.else_leads;
                    var consumed_else = false;
                    if (then_guard) {
                        const if_stmt = try a.create(Stmt);
                        if_stmt.* = .{ .if_stmt = .{
                            .condition = parts.condition,
                            .body = parts.then_body,
                            .else_body = &.{},
                        } };
                        try stmts.append(a, if_stmt);
                        if (parts.else_body.len > 0) {
                            try stmts.appendSlice(a, parts.else_body);
                        }
                        consumed_else = true;
                    } else if (else_cont) {
                        const else_is_jump_target = self.elseIsJumpTarget(parts.cond_op);
                        var emitted_then_if = false;
                        const prefer_if = parts.condition.* == .bool_op;
                        if ((else_is_jump_target and parts.else_body.len == 0 and parts.then_body.len > 0) or
                            (prefer_if and !else_is_jump_target and parts.else_body.len == 0 and parts.then_body.len > 0 and !self.bodyEndsTerminal(parts.then_body)))
                        {
                            const if_stmt = try a.create(Stmt);
                            if_stmt.* = .{ .if_stmt = .{
                                .condition = parts.condition,
                                .body = parts.then_body,
                                .else_body = &.{},
                            } };
                            try stmts.append(a, if_stmt);
                            emitted_then_if = true;
                        } else {
                            const guard_cond = try self.guardCondForBranch(parts.condition, parts.cond_op, else_is_jump_target);
                            var guard_body = parts.else_body;
                            var needs_continue = true;
                            if (guard_body.len > 0) {
                                const last = guard_body[guard_body.len - 1];
                                if (last.* == .continue_stmt or self.stmtIsTerminal(last)) {
                                    needs_continue = false;
                                }
                            }
                            if (needs_continue) {
                                const cont = try self.makeContinue();
                                const next_body = try a.alloc(*Stmt, guard_body.len + 1);
                                if (guard_body.len > 0) {
                                    std.mem.copyForwards(*Stmt, next_body[0..guard_body.len], guard_body);
                                }
                                next_body[guard_body.len] = cont;
                                guard_body = next_body;
                            }
                            const guard_stmt = try a.create(Stmt);
                            guard_stmt.* = .{ .if_stmt = .{
                                .condition = guard_cond,
                                .body = guard_body,
                                .else_body = &.{},
                            } };
                            try stmts.append(a, guard_stmt);
                        }
                        if (!emitted_then_if and parts.then_body.len > 0) {
                            try stmts.appendSlice(a, parts.then_body);
                        }
                        consumed_else = true;
                    } else {
                        const if_stmt = try a.create(Stmt);
                        if_stmt.* = .{ .if_stmt = .{
                            .condition = parts.condition,
                            .body = parts.then_body,
                            .else_body = parts.else_body,
                        } };
                        try stmts.append(a, if_stmt);
                    }

                    if (parts.else_is_continuation and !consumed_else) {
                        if (parts.else_block) |else_id| {
                            const else_res = self.resolveJumpOnlyBlock(else_id);
                            if (else_res != loop_header and else_id > block_idx) {
                                if (stop_block) |stop_id| {
                                    if (else_id == stop_id) break;
                                }
                                block_idx = else_id;
                                continue;
                            }
                        }
                    }

                    if (try self.nextLoopBlockAfterIf(p, loop_header, block_idx, stop_block)) |next_id| {
                        block_idx = next_id;
                        continue;
                    }
                    block_idx += 1;
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
                    const result = try self.decompileTryWithLoop(p, loop_header, visited);
                    const leave_loop = self.tryNeedsBreak(&p, loop_header);
                    if (result.stmt) |s| {
                        if (leave_loop) {
                            try self.appendTryBreak(s);
                        }
                        try stmts.append(a, s);
                    }
                    if (leave_loop) break;
                    block_idx = result.next_block;
                    continue;
                },
                .while_loop => |p| {
                    const stmt = try self.decompileWhile(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    self.markLoopVisited(p.header_block, visited);
                    if (self.loop_next) |next| {
                        block_idx = next;
                        self.loop_next = null;
                    } else {
                        block_idx = p.exit_block;
                    }
                    continue;
                },
                .for_loop => |p| {
                    if (try self.tryDecompileInlineListComp(p)) |result| {
                        deinitStackValuesSlice(self.allocator, self.allocator, result.stack);
                        block_idx = result.exit_block;
                        continue;
                    }
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try stmts.append(a, s);
                    }
                    self.markLoopVisited(p.header_block, visited);
                    block_idx = p.exit_block;
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
                    try self.emitMatchPrelude(p.subject_block, &stmts, a);
                    const result = try self.decompileMatch(p);
                    if (result.stmt) |s| {
                        try stmts.append(a, s);
                    }
                    block_idx = result.next_block;
                    continue;
                },
                else => {
                    // Process statements, stopping at back edge
                    const skip_body = if (block_idx == start_block) skip_first else 0;
                    try self.processBlockStatements(
                        block_idx,
                        block,
                        &stmts,
                        skip_first_store,
                        seed_pop,
                        has_back_edge,
                        loop_header,
                        skip_body,
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
                        if (next_id == loop_header) break;
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

    fn unmangleClassName(self: *Decompiler, name: []const u8) DecompileError![]const u8 {
        return name_mangle.unmangleClassName(self.arena.allocator(), self.class_name, name);
    }

    fn makeName(self: *Decompiler, name: []const u8, ctx: ExprContext) DecompileError!*Expr {
        const unmangled = try self.unmangleClassName(name);
        return ast.makeName(self.arena.allocator(), unmangled, ctx);
    }

    fn makeAttribute(self: *Decompiler, value: *Expr, attr: []const u8, ctx: ExprContext) DecompileError!*Expr {
        const unmangled = try self.unmangleClassName(attr);
        return ast.makeAttribute(self.arena.allocator(), value, unmangled, ctx);
    }

    fn initSim(self: *Decompiler, allocator: Allocator, stack_alloc: Allocator, code: *const pyc.Code, version: Version) SimContext {
        var sim = SimContext.init(allocator, stack_alloc, code, version);
        sim.class_name = self.class_name;
        return sim;
    }

    fn decompileNestedBody(self: *Decompiler, code: *const pyc.Code) DecompileError![]const *Stmt {
        return self.decompileNestedBodyWithClass(code, self.class_name);
    }

    fn decompileNestedBodyWithClass(self: *Decompiler, code: *const pyc.Code, class_name: ?[]const u8) DecompileError![]const *Stmt {
        const nested_ptr = try self.allocator.create(Decompiler);
        errdefer self.allocator.destroy(nested_ptr);

        nested_ptr.* = try Decompiler.init(self.allocator, code, self.version);
        errdefer nested_ptr.deinit();
        nested_ptr.class_name = class_name;
        nested_ptr.clone_sim.class_name = class_name;

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

        // Nonlocal: only freevars that are assigned in this scope
        var nonlocals: std.StringHashMapUnmanaged(void) = .{};
        defer nonlocals.deinit(a);
        if (func.code.freevars.len > 0) {
            var it_nonlocal = decoder.InstructionIterator.init(func.code.code, self.version);
            while (it_nonlocal.next()) |inst| {
                if (inst.opcode == .STORE_DEREF or inst.opcode == .DELETE_DEREF) {
                    if (inst.arg < func.code.cellvars.len) continue;
                    const free_idx: usize = @as(usize, inst.arg) - func.code.cellvars.len;
                    if (free_idx < func.code.freevars.len) {
                        try nonlocals.put(a, func.code.freevars[free_idx], {});
                    }
                }
            }
        }
        if (nonlocals.count() > 0) {
            const names = try a.alloc([]const u8, nonlocals.count());
            var it = nonlocals.keyIterator();
            var i: usize = 0;
            while (it.next()) |key| : (i += 1) {
                names[i] = try self.unmangleClassName(key.*);
            }
            const nl_stmt = try a.create(Stmt);
            nl_stmt.* = .{ .nonlocal_stmt = .{ .names = names } };
            try decls.append(a, nl_stmt);
        }

        // Global: scan bytecode for STORE_GLOBAL
        var globals: std.StringHashMapUnmanaged(void) = .{};
        defer globals.deinit(a);
        var iter = decoder.InstructionIterator.init(func.code.code, self.version);
        while (iter.next()) |inst| {
            if (inst.opcode == .STORE_GLOBAL) {
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
                names[i] = try self.unmangleClassName(key.*);
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

        const args = try signature.extractFunctionSignature(a, func.code, self.class_name, func.defaults, func.kw_defaults, func.annotations);

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

        const class_name_for_body = if (cls.name.len > 0) cls.name else name;
        var body = try self.decompileNestedBodyWithClass(cls.code, class_name_for_body);
        body = try self.trimTrailingReturnNone(body);

        // Python 2.x classes: trim trailing "return locals()"
        if (body.len > 0 and Decompiler.isReturnLocals(body[body.len - 1])) {
            body = body[0 .. body.len - 1];
        }

        body = self.trimClassPrelude(body, class_name_for_body);

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
        const keywords = cls.keywords;
        cls.bases = &.{};
        cls.keywords = &.{};

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
            .keywords = keywords,
            .body = body,
            .decorator_list = decorator_list,
        } };

        return stmt;
    }

    fn handleStoreValue(self: *Decompiler, name: []const u8, value: stack_mod.StackValue) DecompileError!?*Stmt {
        const a = self.arena.allocator();
        if (self.isModuleLevel() and std.mem.eql(u8, name, "__doc__") and self.statements.items.len == 0) {
            if (value == .expr and value.expr.* == .constant and value.expr.constant == .string) {
                return try self.makeExprStmt(value.expr);
            }
        }
        const out_name = try self.unmangleClassName(name);
        return switch (value) {
            .expr => |expr| blk: {
                const target = try self.makeName(out_name, .store);
                break :blk try self.makeAssign(target, expr);
            },
            .function_obj => |func| try self.makeFunctionDef(out_name, func),
            .class_obj => |cls| try self.makeClassDef(out_name, cls),
            .import_module => |imp| try self.makeImport(out_name, imp),
            .saved_local => null,
            .code_obj, .comp_obj, .comp_builder, .null_marker, .unknown => blk: {
                // Fallback for unhandled stack values - emit a valid placeholder
                const placeholder = try ast.makeConstant(a, .ellipsis);
                const target = try self.makeName(out_name, .store);
                break :blk try self.makeAssign(target, placeholder);
            },
        };
    }

    fn tryRecoverFunctionDefFromMakeFunction(
        self: *Decompiler,
        sim: *SimContext,
        instructions: []const decoder.Instruction,
        inst_idx: usize,
        name: []const u8,
    ) DecompileError!?*Stmt {
        if (inst_idx == 0 or inst_idx > instructions.len) return null;
        const make_inst = instructions[inst_idx - 1];
        if (make_inst.opcode != .MAKE_FUNCTION) return null;

        const flags: u32 = make_inst.arg;
        if ((flags & ~@as(u32, 0x01)) != 0) return null;
        if (inst_idx < 3) return null;
        const qual_inst = instructions[inst_idx - 2];
        const code_inst = instructions[inst_idx - 3];
        if (qual_inst.opcode != .LOAD_CONST or code_inst.opcode != .LOAD_CONST) return null;
        const code_obj = sim.getConst(code_inst.arg) orelse return null;
        const code = switch (code_obj) {
            .code, .code_ref => |c| c,
            else => return null,
        };

        var defaults: []const *Expr = &.{};
        if ((flags & 0x01) != 0) {
            if (inst_idx < 4) return null;
            const def_inst = instructions[inst_idx - 4];
            if (def_inst.opcode != .LOAD_CONST) return null;
            if (sim.getConst(def_inst.arg)) |def_obj| {
                const def_expr = try sim.objToExpr(def_obj);
                if (def_expr.* == .tuple) {
                    defaults = def_expr.tuple.elts;
                } else {
                    def_expr.deinit(sim.allocator);
                    sim.allocator.destroy(def_expr);
                }
            }
        }

        const func = try self.allocator.create(stack_mod.FunctionValue);
        func.* = .{
            .code = code,
            .decorators = .{},
            .defaults = defaults,
            .kw_defaults = &.{},
            .annotations = &.{},
        };

        return try self.makeFunctionDef(name, func);
    }

    fn tryDecompileImportFromGroup(
        self: *Decompiler,
        sim: *SimContext,
        instructions: []const decoder.Instruction,
        start_idx: usize,
        stmts: *std.ArrayList(*Stmt),
        stmts_allocator: Allocator,
    ) DecompileError!?usize {
        if (start_idx >= instructions.len) return null;
        const inst = instructions[start_idx];
        if (inst.opcode != .IMPORT_NAME) return null;

        const module_name = sim.getName(inst.arg) orelse return null;
        const stack_items = sim.stack.items.items;
        const fromlist_val = if (stack_items.len > 0) stack_items[stack_items.len - 1] else null;
        var level: u32 = 0;
        if (self.version.gte(2, 5) and stack_items.len >= 2) {
            const level_val = stack_items[stack_items.len - 2];
            if (level_val == .expr and level_val.expr.* == .constant) {
                if (level_val.expr.constant == .int and level_val.expr.constant.int >= 0) {
                    level = @intCast(level_val.expr.constant.int);
                }
            }
        }

        if (self.version.gte(2, 0)) {
            if (fromlist_val) |fv| {
                if (fv == .expr and fv.expr.* == .tuple) {
                    if (fv.expr.tuple.elts.len == 0) return null;
                } else {
                    return null;
                }
            } else {
                return null;
            }
        }

        var idx = start_idx + 1;
        var aliases: std.ArrayList(ast.Alias) = .{};
        defer aliases.deinit(self.allocator);

        if (idx < instructions.len and instructions[idx].opcode == .IMPORT_STAR) {
            const a = self.arena.allocator();
            const list = try a.alloc(ast.Alias, 1);
            list[0] = .{ .name = "*", .asname = null };
            const stmt = try a.create(Stmt);
            stmt.* = .{ .import_from = .{
                .module = if (module_name.len == 0) null else module_name,
                .names = list,
                .level = level,
            } };
            try stmts.append(stmts_allocator, stmt);

            var sim_idx: usize = start_idx;
            while (sim_idx <= idx) : (sim_idx += 1) {
                try sim.simulate(instructions[sim_idx]);
            }
            return idx;
        }

        while (idx + 1 < instructions.len) {
            const from_inst = instructions[idx];
            const store_inst = instructions[idx + 1];
            if (from_inst.opcode != .IMPORT_FROM) break;
            const attr_name = sim.getName(from_inst.arg) orelse break;
            const store_name: ?[]const u8 = switch (store_inst.opcode) {
                .STORE_NAME, .STORE_GLOBAL => sim.getName(store_inst.arg),
                .STORE_FAST => sim.getLocal(store_inst.arg),
                .STORE_DEREF => sim.getDeref(store_inst.arg),
                else => null,
            };
            if (store_name == null) break;
            const asname = if (std.mem.eql(u8, attr_name, store_name.?)) null else store_name.?;
            try aliases.append(self.allocator, .{ .name = attr_name, .asname = asname });
            idx += 2;
        }

        if (aliases.items.len == 0) return null;
        if (idx >= instructions.len or instructions[idx].opcode != .POP_TOP) return null;

        const a = self.arena.allocator();
        const alias_list = try a.alloc(ast.Alias, aliases.items.len);
        std.mem.copyForwards(ast.Alias, alias_list, aliases.items);
        const stmt = try a.create(Stmt);
        stmt.* = .{ .import_from = .{
            .module = if (module_name.len == 0) null else module_name,
            .names = alias_list,
            .level = level,
        } };
        try stmts.append(stmts_allocator, stmt);

        var sim_idx: usize = start_idx;
        while (sim_idx <= idx) : (sim_idx += 1) {
            try sim.simulate(instructions[sim_idx]);
        }

        return idx;
    }

    fn makeImport(self: *Decompiler, alias_name: []const u8, imp: stack_mod.ImportModule) DecompileError!*Stmt {
        const a = self.arena.allocator();
        const stmt = try a.create(ast.Stmt);

        if (imp.fromlist.len == 0) {
            // import module or import module as alias
            const base = blk: {
                if (imp.module.len == 0) break :blk imp.module;
                if (std.mem.indexOfScalar(u8, imp.module, '.')) |dot| {
                    break :blk imp.module[0..dot];
                }
                break :blk imp.module;
            };
            const asname = if (std.mem.eql(u8, alias_name, base)) null else alias_name;
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
            const module_name: ?[]const u8 = if (imp.module.len == 0) null else imp.module;
            stmt.* = .{ .import_from = .{
                .module = module_name,
                .names = aliases,
                .level = imp.level,
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

        const container = try self.makeName(container_name.?, .load);
        idx += 1;

        if (idx >= instructions.len) return null;
        const next = instructions[idx];

        // Check for STORE_ATTR (container.attr)
        if (next.opcode == .STORE_ATTR) {
            const attr_name = sim.getName(next.arg) orelse return null;
            const target = try self.makeAttribute(container, attr_name, .store);
            return .{ .target = target, .next_idx = idx + 1 };
        }

        // Check for BUILD_SLICE pattern: LOAD start, LOAD stop, [LOAD step], BUILD_SLICE, STORE_SUBSCR
        // Or simple key: LOAD key, STORE_SUBSCR
        const key_or_start: ?*Expr = try parseLoadExpr(self, sim, arena, next);
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
        const stop: ?*Expr = try parseLoadExpr(self, sim, arena, stop_inst);
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
            step = try parseLoadExpr(self, sim, arena, maybe_step_or_build);
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
    fn parseLoadExpr(self: *Decompiler, sim: *SimContext, arena: Allocator, inst: decoder.Instruction) DecompileError!?*Expr {
        return switch (inst.opcode) {
            .LOAD_NAME, .LOAD_GLOBAL => blk: {
                const name = sim.getName(inst.arg) orelse break :blk null;
                break :blk try self.makeName(name, .load);
            },
            .LOAD_FAST => blk: {
                const name = sim.getLocal(inst.arg) orelse break :blk null;
                break :blk try self.makeName(name, .load);
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
        // Suppress placeholders from appearing as statements
        if (value.* == .name) {
            if (std.mem.eql(u8, value.name.id, "__exception__") or std.mem.eql(u8, value.name.id, "__unknown__") or std.mem.eql(u8, value.name.id, "_")) {
                return error.SkipStatement;
            }
        }
        if (value.* == .call) {
            const func = value.call.func;
            if (func.* == .name) {
                if (std.mem.eql(u8, func.name.id, "__with_exit__")) {
                    return error.SkipStatement;
                }
                if (std.mem.eql(u8, func.name.id, "__unknown__")) {
                    const args = value.call.args;
                    if (args.len == 3) {
                        var all_none = true;
                        for (args) |arg| {
                            if (arg.* != .constant or arg.constant != .none) {
                                all_none = false;
                                break;
                            }
                        }
                        if (all_none) return error.SkipStatement;
                    }
                }
            }
        }
        const a = self.arena.allocator();
        const stmt = try a.create(Stmt);
        stmt.* = .{ .expr_stmt = .{
            .value = value,
        } };
        return stmt;
    }

    fn isPlaceholderExpr(self: *Decompiler, value: *const Expr) bool {
        _ = self;
        if (value.* != .name) return false;
        return std.mem.eql(u8, value.name.id, "__exception__") or std.mem.eql(u8, value.name.id, "__unknown__");
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

    /// Check if a statement is `return locals()` (Python 2.x class body).
    fn isReturnLocals(stmt: *const Stmt) bool {
        if (stmt.* != .return_stmt) return false;
        const ret = stmt.return_stmt;
        if (ret.value) |val| {
            if (val.* == .call) {
                const call = val.call;
                if (call.func.* == .name and std.mem.eql(u8, call.func.name.id, "locals")) {
                    return call.args.len == 0;
                }
            }
        }
        return false;
    }

    /// Check if this is module-level code.
    fn isModuleLevel(self: *const Decompiler) bool {
        return std.mem.eql(u8, self.code.name, "<module>");
    }
};

pub fn computeStackDepthsForTest(
    allocator: Allocator,
    code: *const pyc.Code,
    version: Version,
) DecompileError![]?usize {
    var decompiler = try Decompiler.init(allocator, code, version);
    defer decompiler.deinit();

    const count: usize = decompiler.cfg.blocks.len;
    const out = try allocator.alloc(?usize, count);
    for (decompiler.stack_in, 0..) |entry_opt, idx| {
        if (entry_opt) |entry| {
            out[idx] = entry.len;
        } else {
            out[idx] = null;
        }
    }
    return out;
}

/// Decompile a code object and write Python source to writer.
pub fn decompileToSource(allocator: Allocator, code: *const pyc.Code, version: Version, writer: anytype) !void {
    return decompileToSourceWithOptions(allocator, code, version, writer, null, .{});
}

/// Decompile with error context output.
pub fn decompileToSourceWithContext(
    allocator: Allocator,
    code: *const pyc.Code,
    version: Version,
    writer: anytype,
    err_writer: ?std.fs.File,
) !void {
    return decompileToSourceWithOptions(allocator, code, version, writer, err_writer, .{});
}

const FocusError = error{
    AmbiguousCodePath,
    CodePathNotFound,
    InvalidFocusPath,
};

pub fn decompileToSourceWithOptions(
    allocator: Allocator,
    code: *const pyc.Code,
    version: Version,
    writer: anytype,
    err_writer: ?std.fs.File,
    opts: DecompileOptions,
) !void {
    var target = code;
    if (opts.focus) |path| {
        target = findCodeByPath(code, path) catch |err| {
            if (err_writer) |ew| {
                var buf: [256]u8 = undefined;
                const msg = switch (err) {
                    error.InvalidFocusPath => try std.fmt.bufPrint(&buf, "Invalid focus path: {s}\n", .{path}),
                    error.CodePathNotFound => try std.fmt.bufPrint(&buf, "Focus path not found: {s}\n", .{path}),
                    error.AmbiguousCodePath => try std.fmt.bufPrint(&buf, "Ambiguous focus path: {s}\n", .{path}),
                };
                _ = try ew.write(msg);
            }
            return err;
        };
    }
    var use_opts = opts;
    use_opts.focus = null;
    // Handle module-level code
    if (std.mem.eql(u8, target.name, "<module>")) {
        var decompiler = try Decompiler.init(allocator, target, version);
        defer decompiler.deinit();
        decompiler.trace_loop_guards = use_opts.trace_loop_guards;
        decompiler.trace_sim_block = use_opts.trace_sim_block;
        decompiler.trace_decisions = use_opts.trace_decisions;
        decompiler.trace_file = use_opts.trace_file;
        if (use_opts.trace_sim_block) |bid| {
            try decompiler.traceSimBlock(bid);
        }

        const stmts = decompiler.decompile() catch |err| {
            if (err_writer) |ew| {
                if (decompiler.last_error_ctx) |ctx| {
                    var buf: [256]u8 = undefined;
                    const msg = try std.fmt.bufPrint(&buf, "Error in {s} at offset {d} ({s}): {s}\n", .{
                        ctx.code_name,
                        ctx.offset,
                        ctx.opcode,
                        @errorName(err),
                    });
                    _ = try ew.write(msg);
                } else {
                    var buf: [128]u8 = undefined;
                    const msg = try std.fmt.bufPrint(&buf, "Error: {s}\n", .{@errorName(err)});
                    _ = try ew.write(msg);
                }
            }
            return err;
        };
        var effective_stmts = stmts;
        while (effective_stmts.len > 0 and Decompiler.isReturnNone(effective_stmts[effective_stmts.len - 1])) {
            effective_stmts = effective_stmts[0 .. effective_stmts.len - 1];
        }

        if (effective_stmts.len == 0) return;

        effective_stmts = try Decompiler.reorderFutureImports(decompiler.arena.allocator(), effective_stmts);
        effective_stmts = try decompiler.mergeImportFromGroupsDeep(decompiler.arena.allocator(), effective_stmts);

        var cg = codegen.Writer.init(allocator);
        defer cg.deinit(allocator);

        var seen_body = false;
        for (effective_stmts) |stmt| {
            const is_doc = Decompiler.isDocstringStmt(stmt);
            const is_future = Decompiler.isFutureImportStmt(stmt);
            if (!seen_body) {
                if (!is_doc and !is_future) seen_body = true;
            } else if (is_future) {
                continue;
            }
            try cg.writeStmt(allocator, stmt);
        }

        const output = try cg.getOutput(allocator);
        defer allocator.free(output);
        const aligned = try alignDefLines(allocator, target, output);
        defer allocator.free(aligned);
        try writer.writeAll(aligned);
        return;
    } else {
        try decompileFunctionToSource(allocator, target, version, writer, 0, use_opts);
    }
}

/// Decompile a function and write to writer.
fn decompileFunctionToSource(
    allocator: Allocator,
    code: *const pyc.Code,
    version: Version,
    writer: anytype,
    indent: u32,
    opts: DecompileOptions,
) !void {
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
        decompiler.trace_loop_guards = opts.trace_loop_guards;
        decompiler.trace_sim_block = opts.trace_sim_block;
        decompiler.trace_decisions = opts.trace_decisions;
        decompiler.trace_file = opts.trace_file;
        if (opts.trace_sim_block) |bid| {
            try decompiler.traceSimBlock(bid);
        }

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
}

fn findCodeByPath(code: *const pyc.Code, path: []const u8) FocusError!*const pyc.Code {
    if (path.len == 0) return error.InvalidFocusPath;
    var it = std.mem.splitScalar(u8, path, '.');
    var cur = code;
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) return error.InvalidFocusPath;
        if (first) {
            if (std.mem.eql(u8, seg, "<module>") or std.mem.eql(u8, seg, cur.name)) {
                first = false;
                continue;
            }
        }
        first = false;
        var found: ?*const pyc.Code = null;
        for (cur.consts) |c| {
            const child = switch (c) {
                .code => c.code,
                .code_ref => c.code_ref,
                else => null,
            };
            if (child) |cc| {
                if (std.mem.eql(u8, cc.name, seg)) {
                    if (found == null) {
                        found = cc;
                    } else if (found.? != cc) {
                        return error.AmbiguousCodePath;
                    }
                }
            }
        }
        if (found == null) return error.CodePathNotFound;
        cur = found.?;
    }
    return cur;
}

const LineInfo = struct {
    text: []const u8,
    indent: usize,
    is_blank: bool,
};

fn splitLines(allocator: Allocator, src: []const u8) ![]LineInfo {
    var lines: std.ArrayList(LineInfo) = .{};
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const is_blank = trimmed.len == 0;
        var indent: usize = 0;
        if (!is_blank) {
            while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
        }
        try lines.append(allocator, .{
            .text = line,
            .indent = indent,
            .is_blank = is_blank,
        });
    }
    if (lines.items.len > 0) {
        const last = lines.items[lines.items.len - 1];
        if (last.is_blank and last.text.len == 0) {
            lines.items.len -= 1;
        }
    }
    return lines.toOwnedSlice(allocator);
}

fn collectDefCodeObjects(allocator: Allocator, code: *const pyc.Code) ![]const *const pyc.Code {
    var items: std.ArrayList(*const pyc.Code) = .{};
    errdefer items.deinit(allocator);
    for (code.consts) |c| {
        const child = switch (c) {
            .code => c.code,
            .code_ref => c.code_ref,
            else => null,
        };
        if (child) |cc| {
            if (cc.name.len == 0) continue;
            if (cc.name[0] == '<') continue;
            try items.append(allocator, cc);
        }
    }
    return items.toOwnedSlice(allocator);
}

fn parseNameAfterPrefix(rest: []const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (c == '(' or c == ':' or c == ' ' or c == '\t') break;
    }
    if (end == 0) return null;
    return rest[0..end];
}

fn parseDefName(line: []const u8, indent: usize) ?[]const u8 {
    if (line.len <= indent) return null;
    const rest = line[indent..];
    if (std.mem.startsWith(u8, rest, "async def ")) {
        return parseNameAfterPrefix(rest["async def ".len..]);
    }
    if (std.mem.startsWith(u8, rest, "def ")) {
        return parseNameAfterPrefix(rest["def ".len..]);
    }
    return null;
}

fn parseClassName(line: []const u8, indent: usize) ?[]const u8 {
    if (line.len <= indent) return null;
    const rest = line[indent..];
    if (!std.mem.startsWith(u8, rest, "class ")) return null;
    return parseNameAfterPrefix(rest["class ".len..]);
}

fn isDecoratorLine(line: []const u8, indent: usize) bool {
    return line.len > indent and line[indent] == '@';
}

fn nextChildByName(children: []const *const pyc.Code, idx: *usize, name: []const u8) ?*const pyc.Code {
    var i = idx.*;
    while (i < children.len) : (i += 1) {
        if (std.mem.eql(u8, children[i].name, name)) {
            idx.* = i + 1;
            return children[i];
        }
    }
    return null;
}

fn writeLine(out: *std.ArrayList(u8), allocator: Allocator, line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn padToLine(out: *std.ArrayList(u8), allocator: Allocator, line_no: *u32, target: u32) !void {
    _ = out;
    _ = allocator;
    _ = line_no;
    _ = target;
}

fn processBlock(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    lines: []const LineInfo,
    idx: *usize,
    indent: usize,
    code: ?*const pyc.Code,
    base_line: u32,
) !u32 {
    var line_no = base_line;
    var children: []const *const pyc.Code = &.{};
    if (code) |c| {
        children = try collectDefCodeObjects(allocator, c);
    }
    defer if (children.len > 0) allocator.free(children);
    var child_pos: usize = 0;

    while (idx.* < lines.len) {
        const line = lines[idx.*];
        if (!line.is_blank and line.indent < indent) break;

        if (line.is_blank) {
            try writeLine(out, allocator, line.text);
            line_no += 1;
            idx.* += 1;
            continue;
        }

        if (line.indent != indent) {
            try writeLine(out, allocator, line.text);
            line_no += 1;
            idx.* += 1;
            continue;
        }

        if (isDecoratorLine(line.text, indent)) {
            const deco_start = idx.*;
            var deco_count: usize = 0;
            while (deco_start + deco_count < lines.len) : (deco_count += 1) {
                const cur = lines[deco_start + deco_count];
                if (cur.is_blank or cur.indent != indent) break;
                if (!isDecoratorLine(cur.text, indent)) break;
            }
            const def_idx = deco_start + deco_count;
            if (def_idx < lines.len) {
                const def_line = lines[def_idx];
                if (!def_line.is_blank and def_line.indent == indent) {
                    const def_name = parseDefName(def_line.text, indent);
                    const cls_name = if (def_name == null) parseClassName(def_line.text, indent) else null;
                    const name = def_name orelse cls_name;
                    if (name) |nm| {
                        var child: ?*const pyc.Code = null;
                        if (children.len > 0) {
                            child = nextChildByName(children, &child_pos, nm);
                        }
                        if (child) |cc| {
                            if (cc.firstlineno > 0) {
                                const deco_u32: u32 = @intCast(deco_count);
                                const target = if (cc.firstlineno > deco_u32)
                                    cc.firstlineno - deco_u32
                                else
                                    cc.firstlineno;
                                try padToLine(out, allocator, &line_no, target);
                            }
                        }
                        var j: usize = 0;
                        while (j < deco_count) : (j += 1) {
                            try writeLine(out, allocator, lines[deco_start + j].text);
                            line_no += 1;
                        }
                        try writeLine(out, allocator, def_line.text);
                        line_no += 1;
                        idx.* = def_idx + 1;
                        const body_indent = indent + 4;
                        line_no = try processBlock(allocator, out, lines, idx, body_indent, child, line_no);
                        continue;
                    }
                }
            }
            // Not followed by def/class; emit decorators as-is.
            var j: usize = 0;
            while (j < deco_count) : (j += 1) {
                try writeLine(out, allocator, lines[deco_start + j].text);
                line_no += 1;
            }
            idx.* = deco_start + deco_count;
            continue;
        }

        const def_name = parseDefName(line.text, indent);
        const cls_name = if (def_name == null) parseClassName(line.text, indent) else null;
        const name = def_name orelse cls_name;
        if (name) |nm| {
            var child: ?*const pyc.Code = null;
            if (children.len > 0) {
                child = nextChildByName(children, &child_pos, nm);
            }
            if (child) |cc| {
                if (cc.firstlineno > 0) {
                    try padToLine(out, allocator, &line_no, cc.firstlineno);
                }
            }
            try writeLine(out, allocator, line.text);
            line_no += 1;
            idx.* += 1;
            const body_indent = indent + 4;
            line_no = try processBlock(allocator, out, lines, idx, body_indent, child, line_no);
            continue;
        }

        try writeLine(out, allocator, line.text);
        line_no += 1;
        idx.* += 1;
    }

    return line_no;
}

fn alignDefLines(allocator: Allocator, code: *const pyc.Code, src: []const u8) ![]const u8 {
    const lines = try splitLines(allocator, src);
    defer allocator.free(lines);
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    var idx: usize = 0;
    const base_line: u32 = 1;
    _ = try processBlock(allocator, &out, lines, &idx, 0, code, base_line);
    return out.toOwnedSlice(allocator);
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

test "simulate condition expr returns null on sim error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const version = Version.init(3, 9);

    const ops = [_]test_utils.OpArg{
        .{ .op = .BINARY_ADD, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const bytecode = try test_utils.emitOpsOwned(allocator, version, &ops);
    const code = try test_utils.allocCode(
        allocator,
        "bad_cond",
        &[_][]const u8{},
        &[_]pyc.Object{},
        bytecode,
        0,
    );
    defer {
        code.deinit();
        allocator.destroy(code);
    }

    var decompiler = try Decompiler.init(allocator, code, version);
    defer decompiler.deinit();

    var stmts: std.ArrayList(*Stmt) = .{};
    defer stmts.deinit(allocator);
    try testing.expect((try decompiler.initCondSim(0, &stmts, allocator)) == null);
    try testing.expect((try decompiler.simulateConditionExpr(0, &.{})) == null);
}

test "condReach uses scratch and finds path" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const version = Version.init(3, 9);

    const ops = [_]test_utils.OpArg{
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 8 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .JUMP_FORWARD, .arg = 2 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const bytecode = try test_utils.emitOpsOwned(allocator, version, &ops);
    const consts = [_]pyc.Object{ .{ .none = {} }, .{ .none = {} }, .{ .none = {} } };
    const code = try test_utils.allocCode(
        allocator,
        "cond_reach",
        &[_][]const u8{},
        &consts,
        bytecode,
        0,
    );
    defer {
        code.deinit();
        allocator.destroy(code);
    }

    var decompiler = try Decompiler.init(allocator, code, version);
    defer decompiler.deinit();

    const start = decompiler.cfg.entry;
    try testing.expect(decompiler.cfg.blocks[start].successors.len > 0);
    const target = decompiler.cfg.blocks[start].successors[0].target;
    const skip = std.math.maxInt(u32);
    try testing.expect(try decompiler.condReach(start, target, skip, skip));
}

test "exception seed handles JUMP_IF_NOT_EXC_MATCH" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const version = Version.init(3, 9);

    const ops = [_]test_utils.OpArg{
        .{ .op = .DUP_TOP, .arg = 0 },
        .{ .op = .LOAD_GLOBAL, .arg = 0 },
        .{ .op = .JUMP_IF_NOT_EXC_MATCH, .arg = 14 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .STORE_FAST, .arg = 0 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const bytecode = try test_utils.emitOpsOwned(allocator, version, &ops);
    const consts = [_]pyc.Object{.{ .none = {} }};
    const code = try test_utils.allocCodeWithNames(
        allocator,
        "exc_seed",
        &[_][]const u8{"e"},
        &[_][]const u8{"Exception"},
        &consts,
        bytecode,
        0,
    );
    defer {
        code.deinit();
        allocator.destroy(code);
    }

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompileToSource(allocator, code, version, out.writer(allocator));
    try testing.expect(out.items.len > 0);
}

test "genset reuse" {
    const allocator = std.testing.allocator;
    var set = try GenSet.init(allocator, 4);
    defer set.deinit(allocator);

    try set.set(allocator, 1);
    try std.testing.expect(set.isSet(1));
    try std.testing.expect(set.list.items.len == 1);

    set.reset();
    try std.testing.expect(!set.isSet(1));
    try std.testing.expect(set.list.items.len == 0);

    try set.set(allocator, 1);
    try std.testing.expect(set.isSet(1));
    try std.testing.expect(set.list.items.len == 1);
}
