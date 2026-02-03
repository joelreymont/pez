//! Control flow analysis and pattern detection.
//!
//! Analyzes CFG to detect structured control flow patterns:
//! - if/elif/else statements
//! - while loops
//! - for loops
//! - try/except/finally blocks

const std = @import("std");
const Allocator = std.mem.Allocator;
const cfg_mod = @import("cfg.zig");
const ast = @import("ast.zig");
const decoder = @import("decoder.zig");
const opcodes = @import("opcodes.zig");
const dom_mod = @import("dom.zig");

pub const CFG = cfg_mod.CFG;
pub const BasicBlock = cfg_mod.BasicBlock;
const Edge = cfg_mod.Edge;
pub const EdgeType = cfg_mod.EdgeType;
pub const Instruction = decoder.Instruction;
pub const Opcode = opcodes.Opcode;
pub const Version = decoder.Version;
pub const Stmt = ast.Stmt;
pub const Expr = ast.Expr;

/// Result of control flow pattern detection.
pub const ControlFlowPattern = union(enum) {
    /// Simple if with optional else.
    if_stmt: IfPattern,
    /// While loop.
    while_loop: WhilePattern,
    /// For loop.
    for_loop: ForPattern,
    /// Try/except/finally statement.
    try_stmt: TryPattern,
    /// With statement.
    with_stmt: WithPattern,
    /// Match statement.
    match_stmt: MatchPattern,
    /// Sequential block (no special control flow).
    sequential: SequentialPattern,
    /// Unknown/unrecognized pattern.
    unknown,
};

/// Pattern for if/elif/else statements.
pub const IfPattern = struct {
    /// Block containing the condition (ends with conditional jump).
    condition_block: u32,
    /// First block of the then-branch.
    then_block: u32,
    /// First block of the else-branch (null if no else).
    else_block: ?u32,
    /// Block where both branches merge (null if both branches exit).
    merge_block: ?u32,
    /// True if this is an elif (nested if in else branch).
    is_elif: bool,
};

/// Pattern for while loops.
pub const WhilePattern = struct {
    /// Block containing the loop condition.
    header_block: u32,
    /// First block of the loop body.
    body_block: u32,
    /// Block after the loop (exit target).
    exit_block: u32,
};

/// Pattern for for loops.
pub const ForPattern = struct {
    /// Block with GET_ITER.
    setup_block: u32,
    /// Block with FOR_ITER (loop header).
    header_block: u32,
    /// First block of the loop body.
    body_block: u32,
    /// First block of the else clause (null if no else).
    else_block: ?u32,
    /// Block after the loop/else.
    exit_block: u32,
};

/// Sequential blocks with no special control flow.
pub const SequentialPattern = struct {
    /// Block IDs in order.
    blocks: []const u32,
};

/// Pattern for try/except/finally statements.
pub const TryPattern = struct {
    /// First block of the try body.
    try_block: u32,
    /// Exception handler blocks (each except clause).
    handlers: []const HandlerInfo,
    /// True if caller owns handlers slice.
    handlers_owned: bool,
    /// First block of the else clause (if any).
    else_block: ?u32,
    /// First block of the finally clause (if any).
    finally_block: ?u32,
    /// Block where control resumes after the try statement.
    exit_block: ?u32,
};

/// Information about an exception handler.
pub const HandlerInfo = struct {
    /// Block ID of the handler entry.
    handler_block: u32,
    /// True if this catches all exceptions (bare except or Exception).
    is_bare: bool,
};

/// Pattern for with statements.
pub const WithPattern = struct {
    /// Block containing the context manager setup (BEFORE_WITH).
    setup_block: u32,
    /// First block of the with body.
    body_block: u32,
    /// Block containing cleanup (WITH_EXCEPT_START, etc.).
    cleanup_block: u32,
    /// Block after the with statement.
    exit_block: u32,
};

/// Pattern for match statements (Python 3.10+).
pub const MatchPattern = struct {
    /// Block that loads the subject (before first case).
    subject_block: u32,
    /// Blocks for each case pattern test.
    case_blocks: []const u32,
    /// Block after all cases (where they merge or wildcard).
    exit_block: ?u32,

    pub fn deinit(self: *const MatchPattern, allocator: Allocator) void {
        allocator.free(self.case_blocks);
    }
};

/// Info about a single match case.
pub const CaseInfo = struct {
    /// Block containing pattern test.
    pattern_block: u32,
    /// First block of case body.
    body_block: u32,
    /// True if this is wildcard case (_).
    is_wildcard: bool,
};

/// Break/continue detection result.
pub const LoopExit = union(enum) {
    /// A break statement (exits the loop).
    break_stmt: struct {
        /// Block containing the break.
        block: u32,
        /// The loop header block being broken from.
        loop_header: u32,
    },
    /// A continue statement (jumps to loop header).
    continue_stmt: struct {
        /// Block containing the continue.
        block: u32,
        /// The loop header block being continued to.
        loop_header: u32,
    },
    /// Not a break or continue.
    none,
};

/// Pattern for ternary expressions (a if cond else b).
pub const TernaryPattern = struct {
    /// Block containing the condition test.
    condition_block: u32,
    /// Block containing the true value.
    true_block: u32,
    /// Block containing the false value.
    false_block: u32,
    /// Block where both branches merge.
    merge_block: u32,
};

/// Pattern for ternary expressions with chained conditions (a and b if cond else c).
pub const TernaryChainPattern = struct {
    /// Blocks containing the condition tests in order.
    condition_blocks: []const u32,
    /// Block containing the true value.
    true_block: u32,
    /// Block containing the false value.
    false_block: u32,
    /// Block where both branches merge.
    merge_block: u32,
    /// True for 'and', false for 'or'.
    is_and: bool,
};

/// Pattern for short-circuit boolean expressions (x and y, x or y).
pub const BoolOpKind = enum {
    pop_top,
    or_pop,
};

pub const BoolOpPattern = struct {
    /// Block containing first operand and condition test.
    condition_block: u32,
    /// Block containing second operand (fallthrough from condition).
    second_block: u32,
    /// Block where both paths merge.
    merge_block: u32,
    /// True for 'and', false for 'or'.
    is_and: bool,
    /// Pattern kind.
    kind: BoolOpKind,
};

/// Pattern for "x and y or z" short-circuit chain.
pub const AndOrPattern = struct {
    /// Block containing the condition test (x).
    condition_block: u32,
    /// Block containing the true value (y).
    true_block: u32,
    /// Block containing the false value (z).
    false_block: u32,
    /// Block where both branches merge.
    merge_block: u32,
};

const BlockFlags = struct {
    has_exception_edge: bool = false,
    has_with_setup: bool = false,
    has_check_exc_match: bool = false,
    has_match_opcode: bool = false,
    has_match_pattern: bool = false,
};

/// Control flow analyzer.
pub const Analyzer = struct {
    cfg: *const CFG,
    dom: *const dom_mod.DomTree,
    allocator: Allocator,
    /// Blocks that have been processed/claimed by a pattern.
    processed: std.DynamicBitSet,
    /// Cached try patterns per block (null if none).
    try_cache: []?TryPattern,
    /// Blocks with try pattern computed.
    try_cache_checked: std.DynamicBitSet,
    /// Scratch visited set for single-pass traversals.
    scratch_seen: std.DynamicBitSet,
    /// Secondary scratch visited set for nested traversals.
    scratch_aux: std.DynamicBitSet,
    /// Scratch queue for single-pass traversals.
    scratch_queue: std.ArrayListUnmanaged(u32) = .{},
    /// Enclosing loop headers per block.
    enclosing_loops: []std.ArrayListUnmanaged(u32),
    /// Per-block cached flags for pattern detection.
    block_flags: []BlockFlags,
    /// Expanded loop regions per header.
    loop_regions: std.AutoHashMap(u32, std.DynamicBitSet),
    /// Post-dominator tree for merge selection.
    postdom: cfg_mod.PostDom,

    pub fn init(allocator: Allocator, cfg_ptr: *const CFG, dom: *const dom_mod.DomTree) !Analyzer {
        const processed = try std.DynamicBitSet.initEmpty(allocator, cfg_ptr.blocks.len);
        const try_cache = try allocator.alloc(?TryPattern, cfg_ptr.blocks.len);
        @memset(try_cache, null);
        const try_cache_checked = try std.DynamicBitSet.initEmpty(allocator, cfg_ptr.blocks.len);
        const scratch_seen = try std.DynamicBitSet.initEmpty(allocator, cfg_ptr.blocks.len);
        const scratch_aux = try std.DynamicBitSet.initEmpty(allocator, cfg_ptr.blocks.len);
        const enclosing_loops = try allocator.alloc(std.ArrayListUnmanaged(u32), cfg_ptr.blocks.len);
        @memset(enclosing_loops, .{});
        errdefer {
            for (enclosing_loops) |*list| {
                list.deinit(allocator);
            }
            allocator.free(enclosing_loops);
        }

        const block_flags = try allocator.alloc(BlockFlags, cfg_ptr.blocks.len);
        errdefer allocator.free(block_flags);
        @memset(block_flags, .{});

        var postdom = try cfg_mod.computePostDom(allocator, cfg_ptr, false);
        errdefer postdom.deinit();

        var analyzer = Analyzer{
            .cfg = cfg_ptr,
            .dom = dom,
            .allocator = allocator,
            .processed = processed,
            .try_cache = try_cache,
            .try_cache_checked = try_cache_checked,
            .scratch_seen = scratch_seen,
            .scratch_aux = scratch_aux,
            .scratch_queue = .{},
            .enclosing_loops = enclosing_loops,
            .block_flags = block_flags,
            .loop_regions = std.AutoHashMap(u32, std.DynamicBitSet).init(allocator),
            .postdom = postdom,
        };
        errdefer analyzer.deinit();
        try analyzer.populateEnclosingLoops();
        analyzer.computeBlockFlags();
        return analyzer;
    }

    pub fn deinit(self: *Analyzer) void {
        self.processed.deinit();
        self.postdom.deinit();
        for (self.try_cache) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.handlers.len > 0 and entry.handlers_owned == false) {
                    self.allocator.free(entry.handlers);
                }
            }
        }
        if (self.try_cache.len > 0) self.allocator.free(self.try_cache);
        self.try_cache_checked.deinit();
        self.scratch_seen.deinit();
        self.scratch_aux.deinit();
        self.scratch_queue.deinit(self.allocator);
        for (self.enclosing_loops) |*list| {
            list.deinit(self.allocator);
        }
        if (self.enclosing_loops.len > 0) self.allocator.free(self.enclosing_loops);
        if (self.block_flags.len > 0) self.allocator.free(self.block_flags);
        var it = self.loop_regions.valueIterator();
        while (it.next()) |bitset| {
            bitset.deinit();
        }
        self.loop_regions.deinit();
    }

    fn resetScratch(self: *Analyzer, set: *std.DynamicBitSet) *std.DynamicBitSet {
        set.setRangeValue(.{ .start = 0, .end = self.cfg.blocks.len }, false);
        return set;
    }

    fn scratchSeen(self: *Analyzer) *std.DynamicBitSet {
        return self.resetScratch(&self.scratch_seen);
    }

    fn scratchAux(self: *Analyzer) *std.DynamicBitSet {
        return self.resetScratch(&self.scratch_aux);
    }

    fn scratchQueue(self: *Analyzer) *std.ArrayListUnmanaged(u32) {
        self.scratch_queue.items.len = 0;
        return &self.scratch_queue;
    }

    fn populateEnclosingLoops(self: *Analyzer) !void {
        if (self.dom.num_blocks == 0) return;
        const headers = try self.dom.getLoopHeaders();
        defer self.allocator.free(headers);
        for (headers) |header| {
            const body = self.loopRegion(header) orelse self.dom.getLoopBody(header) orelse continue;
            var it = body.iterator(.{});
            while (it.next()) |idx| {
                if (idx >= self.enclosing_loops.len) continue;
                try self.enclosing_loops[idx].append(self.allocator, header);
            }
            if (header < self.enclosing_loops.len) {
                try self.enclosing_loops[header].append(self.allocator, header);
            }
        }
    }

    fn loopExitBlock(self: *Analyzer, header: u32) ?u32 {
        if (header >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[header];
        if (self.dom.getLoopBody(header)) |body| {
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (!body.isSet(@intCast(edge.target))) {
                    return edge.target;
                }
            }
        }
        if (block.terminator() == null) return null;
        var exit_id: ?u32 = null;
        for (block.successors) |edge| {
            if (edge.edge_type == .conditional_false) {
                exit_id = edge.target;
                break;
            }
        }
        return exit_id;
    }

    fn loopBodySeed(self: *Analyzer, header: u32) ?u32 {
        if (header >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[header];
        if (self.dom.getLoopBody(header)) |body| {
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (body.isSet(@intCast(edge.target))) return edge.target;
            }
        }
        var body_id: ?u32 = null;
        for (block.successors) |edge| {
            if (edge.edge_type == .conditional_true) return edge.target;
            if (edge.edge_type == .normal and body_id == null) {
                body_id = edge.target;
            }
        }
        return body_id;
    }

    fn loopRegion(self: *Analyzer, header: u32) ?*const std.DynamicBitSet {
        if (self.loop_regions.getPtr(header)) |ptr| return ptr;
        var region = if (self.computeLoopRegion(header)) |val| val else |err| {
            if (err == error.NoLoopExit) return null;
            std.debug.panic("loopRegion compute failed: {s}", .{@errorName(err)});
        };
        if (self.loop_regions.put(header, region)) |_| {} else |err| {
            region.deinit();
            std.debug.panic("loopRegion cache failed: {s}", .{@errorName(err)});
        }
        return self.loop_regions.getPtr(header);
    }

    fn computeLoopRegion(self: *Analyzer, header: u32) !std.DynamicBitSet {
        const exit_id = self.loopExitBlock(header) orelse return error.NoLoopExit;
        const body_id = self.loopBodySeed(header) orelse return error.NoLoopExit;
        if (try self.reachesHeader(exit_id, header)) return error.NoLoopExit;
        const header_block = &self.cfg.blocks[header];
        const exit_block = &self.cfg.blocks[exit_id];
        if (exit_block.start_offset <= header_block.start_offset) return error.NoLoopExit;

        var body = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        body.set(@intCast(header));

        var stack: std.ArrayListUnmanaged(u32) = .{};
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, body_id);

        while (stack.items.len > 0) {
            const id = stack.pop() orelse break;
            if (id >= self.cfg.blocks.len) continue;
            if (id == exit_id) continue;
            const blk = &self.cfg.blocks[id];
            if (blk.start_offset >= exit_block.start_offset) continue;
            if (!self.dom.dominates(header, id)) continue;
            if (body.isSet(@intCast(id))) continue;
            body.set(@intCast(id));
            for (blk.successors) |edge| {
                if (edge.target >= self.cfg.blocks.len) continue;
                if (edge.target == exit_id) continue;
                try stack.append(self.allocator, edge.target);
            }
        }
        return body;
    }

    pub fn inLoop(self: *Analyzer, block: u32, header: u32) bool {
        if (block == header) return true;
        if (self.loopRegion(header)) |body| {
            if (block >= self.cfg.blocks.len) return false;
            if (body.isSet(@intCast(block))) return true;
        }
        return self.dom.isInLoop(block, header);
    }

    pub fn loopSet(self: *Analyzer, header: u32) ?*const std.DynamicBitSet {
        return self.loopRegion(header) orelse self.dom.getLoopBody(header);
    }

    fn computeBlockFlags(self: *Analyzer) void {
        for (self.cfg.blocks, 0..) |*block, idx| {
            var flags = BlockFlags{};

            for (block.successors) |edge| {
                if (edge.edge_type == .exception) {
                    flags.has_exception_edge = true;
                    break;
                }
            }

            var has_dup = false;
            var has_exc_cmp = false;
            var has_jump = false;
            for (block.instructions) |inst| {
                switch (inst.opcode) {
                    .BEFORE_WITH, .BEFORE_ASYNC_WITH, .LOAD_SPECIAL, .SETUP_WITH, .SETUP_ASYNC_WITH => {
                        flags.has_with_setup = true;
                    },
                    .CHECK_EXC_MATCH, .CHECK_EG_MATCH, .PUSH_EXC_INFO, .JUMP_IF_NOT_EXC_MATCH => {
                        flags.has_check_exc_match = true;
                    },
                    .DUP_TOP => has_dup = true,
                    .COMPARE_OP => {
                        if (inst.arg == 10) has_exc_cmp = true;
                    },
                    .JUMP_IF_FALSE, .POP_JUMP_IF_FALSE => has_jump = true,
                    .MATCH_SEQUENCE, .MATCH_MAPPING, .MATCH_CLASS => flags.has_match_opcode = true,
                    else => {},
                }
            }

            if (!flags.has_check_exc_match and has_dup and has_exc_cmp and has_jump) {
                flags.has_check_exc_match = true;
            }

            flags.has_match_pattern = self.computeMatchPattern(@intCast(idx), block, flags.has_match_opcode);

            self.block_flags[idx] = flags;
        }
    }

    /// Detect the control flow pattern starting at a block.
    pub fn detectPattern(self: *Analyzer, block_id: u32) !ControlFlowPattern {
        return self.detectPatternInner(block_id, false, false);
    }

    pub fn detectPatternNoTry(self: *Analyzer, block_id: u32) !ControlFlowPattern {
        return self.detectPatternInner(block_id, true, false);
    }

    pub fn detectPatternNoTryInLoop(self: *Analyzer, block_id: u32) !ControlFlowPattern {
        return self.detectPatternInner(block_id, true, true);
    }

    pub fn detectPatternInLoop(self: *Analyzer, block_id: u32) !ControlFlowPattern {
        return self.detectPatternInner(block_id, false, true);
    }

    fn detectPatternInner(
        self: *Analyzer,
        block_id: u32,
        skip_try: bool,
        allow_loop_if: bool,
    ) !ControlFlowPattern {
        if (block_id >= self.cfg.blocks.len) return .unknown;
        if (self.processed.isSet(block_id)) return .unknown;

        const block = &self.cfg.blocks[block_id];
        const term = block.terminator() orelse return .unknown;
        const has_try_setup = self.hasTrySetup(block);

        // Check for exception handler with CHECK_EXC_MATCH - not a regular if
        if (block.is_exception_handler or self.hasCheckExcMatch(block)) {
            return .unknown;
        }

        // Skip exception table infrastructure (POP_JUMP_FORWARD_IF_NOT_NONE without preceding code)
        if (term.opcode == .POP_JUMP_FORWARD_IF_NOT_NONE) {
            return .unknown;
        }

        // Check for match statement (before if, since match uses conditional jumps)
        if (self.isMatchSubjectBlock(block)) {
            if (try self.detectMatchPattern(block_id)) |pattern| {
                return .{ .match_stmt = pattern };
            }
        }

        // Check for loop header (while loop pattern) before generic if.
        if (block.is_loop_header) {
            if (self.detectWhilePattern(block_id, allow_loop_if)) |pattern| {
                return .{ .while_loop = pattern };
            }
            const async_for_header = self.isAsyncForHeader(block);
            // Loop headers that don't form a well-structured while shouldn't be treated as if.
            if (!allow_loop_if and term.opcode != .FOR_ITER and term.opcode != .FOR_LOOP and !async_for_header) {
                return .unknown;
            }
        }

        // Check for with statement (BEFORE_WITH opcode)
        if (self.hasWithSetup(block)) {
            if (self.detectWithPattern(block_id)) |pattern| {
                return .{ .with_stmt = pattern };
            }
        }

        // Check for conditional jump (if statement pattern)
        // Skip POP_JUMP_FORWARD_IF_NOT_NONE - exception table infrastructure
        const allow_if = if (skip_try) true else !has_try_setup;
        if (allow_if and self.isConditionalJump(term.opcode) and term.opcode != .POP_JUMP_FORWARD_IF_NOT_NONE) {
            if (try self.detectIfPattern(block_id)) |pattern| {
                return .{ .if_stmt = pattern };
            }
        }

        // Check for FOR_ITER/FOR_LOOP (for loop pattern)
        if (term.opcode == .FOR_ITER or term.opcode == .FOR_LOOP) {
            if (self.detectForPattern(block_id)) |pattern| {
                return .{ .for_loop = pattern };
            }
        }

        // Check for try/except pattern (block with exception edge or explicit setup)
        if (!skip_try) {
            if (self.hasExceptionEdge(block) or has_try_setup) {
                if (try self.detectTryPattern(block_id)) |pattern| {
                    return .{ .try_stmt = pattern };
                }
            }
        }

        return .unknown;
    }

    pub fn detectTryPatternAt(self: *Analyzer, block_id: u32) !?TryPattern {
        return self.detectTryPattern(block_id);
    }

    /// Check if block has any exception edges.
    pub fn hasExceptionEdge(self: *const Analyzer, block: *const BasicBlock) bool {
        if (block.id >= self.block_flags.len) return false;
        return self.block_flags[block.id].has_exception_edge;
    }

    fn isTerminalBlock(self: *const Analyzer, block_id: u32) bool {
        if (block_id >= self.cfg.blocks.len) return true;
        const block = &self.cfg.blocks[block_id];
        for (block.successors) |edge| {
            if (edge.edge_type != .exception) return false;
        }
        return true;
    }

    pub fn isTerminalGuardBlock(self: *const Analyzer, block_id: u32) bool {
        if (block_id >= self.cfg.blocks.len) return false;
        const blk = &self.cfg.blocks[block_id];
        const term = blk.terminator() orelse return false;
        if (!self.isConditionalJump(term.opcode)) return false;
        var count: usize = 0;
        for (blk.successors) |edge| {
            if (edge.edge_type == .exception) continue;
            count += 1;
            var tgt = edge.target;
            if (self.jumpOnlyTarget(tgt)) |jump_tgt| {
                tgt = jump_tgt;
            }
            if (!self.isTerminalBlock(tgt)) return false;
        }
        return count > 0;
    }

    /// Check if block has BEFORE_WITH setup.
    fn hasWithSetup(self: *const Analyzer, block: *const BasicBlock) bool {
        if (block.id >= self.block_flags.len) return false;
        return self.block_flags[block.id].has_with_setup;
    }

    /// Check if block has SETUP_EXCEPT/SETUP_FINALLY (try header).
    fn hasTrySetup(self: *const Analyzer, block: *const BasicBlock) bool {
        if (self.cfg.version.gte(3, 11)) return false;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .SETUP_EXCEPT, .SETUP_FINALLY => return true,
                else => {},
            }
        }
        return false;
    }

    fn isAsyncForHeader(self: *const Analyzer, block: *const BasicBlock) bool {
        if (self.cfg.version.lt(3, 5)) return false;
        var has_setup = false;
        var has_anext = false;
        var has_yield = false;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .SETUP_EXCEPT, .SETUP_FINALLY => has_setup = true,
                .GET_ANEXT => has_anext = true,
                .YIELD_FROM => has_yield = true,
                else => {},
            }
        }
        return has_setup and has_anext and has_yield;
    }

    /// Check if block has CHECK_EXC_MATCH (exception handler).
    fn hasCheckExcMatch(self: *const Analyzer, block: *const BasicBlock) bool {
        if (block.id >= self.block_flags.len) return false;
        return self.block_flags[block.id].has_check_exc_match;
    }

    /// Detect ternary expression pattern.
    /// A ternary has the form: value_if_true if condition else value_if_false
    /// In bytecode: condition, POP_JUMP_IF_FALSE, true_expr, JUMP_FORWARD, false_expr
    pub fn detectTernary(self: *const Analyzer, block_id: u32) ?TernaryPattern {
        if (block_id >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[block_id];
        const term = block.terminator() orelse return null;

        // Must end with conditional jump
        if (!self.isConditionalJump(term.opcode)) return null;
        if (block.successors.len != 2) return null;

        var true_block: ?u32 = null;
        var false_block: ?u32 = null;

        for (block.successors) |edge| {
            if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                true_block = edge.target;
            } else if (edge.edge_type == .conditional_false) {
                false_block = edge.target;
            }
        }

        const true_id = true_block orelse return null;
        const false_id = false_block orelse return null;

        // Both blocks should be small (1-2 instructions typically for ternary)
        // and should merge immediately
        const true_blk = &self.cfg.blocks[true_id];
        const false_blk = &self.cfg.blocks[false_id];

        // Check if both blocks merge to the same successor
        var true_merge: ?u32 = null;
        var false_merge: ?u32 = null;

        for (true_blk.successors) |edge| {
            if (edge.edge_type == .normal) {
                true_merge = edge.target;
                break;
            }
        }

        for (false_blk.successors) |edge| {
            if (edge.edge_type == .normal) {
                false_merge = edge.target;
                break;
            }
        }

        // For a ternary, the true block jumps past the false block
        // So true_merge should equal false_id + 1 or be the same as false_merge
        if (true_merge == null or false_merge == null) return null;

        // Check if they merge at the same point
        // true_merge might equal false_id (true jumps to end of false block)
        // or they might both go to the same place
        const merge = if (true_merge == false_id)
            false_merge.?
        else if (true_merge == false_merge)
            true_merge.?
        else
            return null;

        return TernaryPattern{
            .condition_block = block_id,
            .true_block = true_id,
            .false_block = false_id,
            .merge_block = merge,
        };
    }

    /// Detect "x and y or z" short-circuit pattern.
    pub fn detectAndOr(self: *const Analyzer, block_id: u32) ?AndOrPattern {
        if (block_id >= self.cfg.blocks.len) return null;
        const cond_blk = &self.cfg.blocks[block_id];
        const term = cond_blk.terminator() orelse return null;
        switch (term.opcode) {
            .POP_JUMP_IF_FALSE, .POP_JUMP_FORWARD_IF_FALSE, .POP_JUMP_BACKWARD_IF_FALSE => {},
            else => return null,
        }
        if (cond_blk.successors.len != 2) return null;

        var true_id: ?u32 = null;
        var false_id: ?u32 = null;
        for (cond_blk.successors) |edge| {
            if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                true_id = edge.target;
            } else if (edge.edge_type == .conditional_false) {
                false_id = edge.target;
            }
        }
        const t_id = true_id orelse return null;
        const f_id = false_id orelse return null;

        const true_blk = &self.cfg.blocks[t_id];
        const true_term = true_blk.terminator() orelse return null;
        if (true_term.opcode != .JUMP_IF_TRUE_OR_POP) return null;
        if (true_blk.successors.len != 2) return null;

        var t_true: ?u32 = null;
        var t_false: ?u32 = null;
        for (true_blk.successors) |edge| {
            if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                t_true = edge.target;
            } else if (edge.edge_type == .conditional_false) {
                t_false = edge.target;
            }
        }
        const merge_id = t_true orelse return null;
        if (t_false == null or t_false.? != f_id) return null;

        const false_blk = &self.cfg.blocks[f_id];
        var false_merge: ?u32 = null;
        var false_cont: ?u32 = null;
        for (false_blk.successors) |edge| {
            if (edge.edge_type == .normal) {
                false_merge = edge.target;
                break;
            }
        }
        if (false_merge == null) {
            if (false_blk.terminator()) |false_term| {
                switch (false_term.opcode) {
                    .JUMP_IF_FALSE_OR_POP, .JUMP_IF_TRUE_OR_POP => {
                        for (false_blk.successors) |edge| {
                            if (edge.edge_type == .exception) continue;
                            if (edge.target == merge_id) {
                                false_merge = merge_id;
                            } else if (false_cont == null) {
                                false_cont = edge.target;
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        if (false_merge == null or false_merge.? != merge_id) return null;

        const merge_blk = &self.cfg.blocks[merge_id];
        for (merge_blk.predecessors) |pred| {
            if (pred != t_id and pred != f_id and (false_cont == null or pred != false_cont.?)) return null;
        }

        return .{
            .condition_block = block_id,
            .true_block = t_id,
            .false_block = f_id,
            .merge_block = merge_id,
        };
    }

    /// Detect ternary expression pattern with chained and/or conditions.
    pub fn detectTernaryChain(self: *const Analyzer, block_id: u32) Allocator.Error!?TernaryChainPattern {
        if (block_id >= self.cfg.blocks.len) return null;

        var cond_blocks: std.ArrayListUnmanaged(u32) = .{};
        var moved = false;
        defer if (!moved) cond_blocks.deinit(self.allocator);

        var is_and: ?bool = null;
        var short_id: ?u32 = null;
        var cont_id: ?u32 = null;
        var cur = block_id;

        while (true) {
            if (cur >= self.cfg.blocks.len) break;
            const blk = &self.cfg.blocks[cur];
            const term = blk.terminator() orelse break;
            if (!self.isConditionalJump(term.opcode)) break;
            if (blk.successors.len != 2) break;

            const jump_is_and = switch (term.opcode) {
                .POP_JUMP_IF_FALSE, .POP_JUMP_FORWARD_IF_FALSE, .POP_JUMP_BACKWARD_IF_FALSE => true,
                .POP_JUMP_IF_TRUE, .POP_JUMP_FORWARD_IF_TRUE, .POP_JUMP_BACKWARD_IF_TRUE => false,
                else => break,
            };

            if (is_and) |v| {
                if (v != jump_is_and) return null;
            } else {
                is_and = jump_is_and;
            }

            var true_id: ?u32 = null;
            var false_id: ?u32 = null;
            for (blk.successors) |edge| {
                if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                    true_id = edge.target;
                } else if (edge.edge_type == .conditional_false) {
                    false_id = edge.target;
                }
            }
            if (true_id == null or false_id == null) return null;

            const short = if (jump_is_and) false_id.? else true_id.?;
            const cont = if (jump_is_and) true_id.? else false_id.?;

            if (short_id) |sid| {
                if (sid != short) return null;
            } else {
                short_id = short;
            }

            try cond_blocks.append(self.allocator, cur);
            cont_id = cont;

            const next_blk = &self.cfg.blocks[cont];
            const next_term = next_blk.terminator() orelse break;
            if (!self.isConditionalJump(next_term.opcode)) break;
            if (next_blk.successors.len != 2) return null;

            const next_is_and = switch (next_term.opcode) {
                .POP_JUMP_IF_FALSE, .POP_JUMP_FORWARD_IF_FALSE, .POP_JUMP_BACKWARD_IF_FALSE => true,
                .POP_JUMP_IF_TRUE, .POP_JUMP_FORWARD_IF_TRUE, .POP_JUMP_BACKWARD_IF_TRUE => false,
                else => return null,
            };
            if (next_is_and != jump_is_and) return null;

            var next_true: ?u32 = null;
            var next_false: ?u32 = null;
            for (next_blk.successors) |edge| {
                if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                    next_true = edge.target;
                } else if (edge.edge_type == .conditional_false) {
                    next_false = edge.target;
                }
            }
            if (next_true == null or next_false == null) return null;

            const next_short = if (next_is_and) next_false.? else next_true.?;
            if (next_short != short) return null;

            cur = cont;
        }

        if (cond_blocks.items.len == 0) return null;
        const chain_is_and = is_and orelse return null;
        const short_target = short_id orelse return null;
        const end_id = cont_id orelse return null;

        const true_id = if (chain_is_and) end_id else short_target;
        const false_id = if (chain_is_and) short_target else end_id;

        const true_blk = &self.cfg.blocks[true_id];
        const false_blk = &self.cfg.blocks[false_id];

        const true_merge = blk: {
            for (true_blk.successors) |edge| {
                if (edge.edge_type == .normal) break :blk edge.target;
            }
            break :blk null;
        };

        const false_merge = blk: {
            for (false_blk.successors) |edge| {
                if (edge.edge_type == .normal) break :blk edge.target;
            }
            break :blk null;
        };

        if (true_merge == null or false_merge == null) return null;

        const merge = if (true_merge == false_id)
            false_merge.?
        else if (true_merge == false_merge)
            true_merge.?
        else
            return null;

        const blocks = try cond_blocks.toOwnedSlice(self.allocator);
        moved = true;
        return .{
            .condition_blocks = blocks,
            .true_block = true_id,
            .false_block = false_id,
            .merge_block = merge,
            .is_and = chain_is_and,
        };
    }

    /// Detect short-circuit boolean expression (x and y, x or y).
    /// Pattern: COPY, TO_BOOL, POP_JUMP, then POP_TOP + second operand.
    pub fn detectBoolOp(self: *const Analyzer, block_id: u32) ?BoolOpPattern {
        if (block_id >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[block_id];
        var non_exc: [2]Edge = undefined;
        var non_exc_len: usize = 0;
        for (block.successors) |edge| {
            if (edge.edge_type == .exception) continue;
            if (non_exc_len < non_exc.len) {
                non_exc[non_exc_len] = edge;
            }
            non_exc_len += 1;
        }
        if (non_exc_len != 2) return null;

        // Check for COPY, TO_BOOL, POP_JUMP pattern at end of block
        const insts = block.instructions;
        if (insts.len == 0) return null;

        const term = block.terminator() orelse return null;

        var kind: BoolOpKind = undefined;
        const is_and = switch (term.opcode) {
            .POP_JUMP_IF_FALSE, .POP_JUMP_FORWARD_IF_FALSE, .POP_JUMP_BACKWARD_IF_FALSE => blk: {
                kind = .pop_top;
                break :blk true;
            },
            .POP_JUMP_IF_TRUE, .POP_JUMP_FORWARD_IF_TRUE, .POP_JUMP_BACKWARD_IF_TRUE => blk: {
                kind = .pop_top;
                break :blk false;
            },
            .JUMP_IF_FALSE_OR_POP => blk: {
                kind = .or_pop;
                break :blk true;
            },
            .JUMP_IF_TRUE_OR_POP => blk: {
                kind = .or_pop;
                break :blk false;
            },
            else => return null,
        };

        if (kind == .pop_top) {
            if (insts.len < 3) return null;
            // Check for TO_BOOL before the jump
            const to_bool_idx = insts.len - 2;
            if (insts[to_bool_idx].opcode != .TO_BOOL) return null;

            // Check for COPY before TO_BOOL
            const copy_idx = insts.len - 3;
            if (insts[copy_idx].opcode != .COPY) return null;
            if (insts[copy_idx].arg != 1) return null;

            // Exclude chained comparison pattern: COMPARE_OP, COPY, TO_BOOL, POP_JUMP
            if (copy_idx >= 1) {
                const prev_op = insts[copy_idx - 1].opcode;
                if (prev_op == .COMPARE_OP) return null;
            }
        }

        // Find the fallthrough (second operand) and jump target blocks
        var second_block: ?u32 = null;
        var short_circuit_block: ?u32 = null;

        for (non_exc[0..2]) |edge| {
            switch (edge.edge_type) {
                .conditional_true, .normal => second_block = edge.target,
                .conditional_false => short_circuit_block = edge.target,
                else => {},
            }
        }

        // For 'and', false branch short-circuits, true branch continues
        // For 'or', true branch short-circuits, false branch continues
        if (is_and) {
            // POP_JUMP_IF_FALSE: fallthrough is second_block, jump is short_circuit
            for (non_exc[0..2]) |edge| {
                switch (edge.edge_type) {
                    .conditional_true, .normal => second_block = edge.target,
                    .conditional_false => short_circuit_block = edge.target,
                    else => {},
                }
            }
        } else {
            // POP_JUMP_IF_TRUE: fallthrough is second_block, jump is short_circuit
            for (non_exc[0..2]) |edge| {
                switch (edge.edge_type) {
                    .conditional_false, .normal => second_block = edge.target,
                    .conditional_true => short_circuit_block = edge.target,
                    else => {},
                }
            }
        }

        const sec_id = second_block orelse return null;
        const short_id = short_circuit_block orelse return null;

        // Verify second block starts with POP_TOP (or NOT_TAKEN + POP_TOP) for pop_top kind
        const sec_blk = &self.cfg.blocks[sec_id];
        if (sec_blk.instructions.len < 1) return null;

        if (kind == .pop_top) {
            var pop_idx: usize = 0;
            if (sec_blk.instructions[0].opcode == .NOT_TAKEN) {
                if (sec_blk.instructions.len < 2) return null;
                pop_idx = 1;
            }
            if (sec_blk.instructions[pop_idx].opcode != .POP_TOP) return null;
        }

        // Both paths should merge at the same point
        const sec_merge = blk: {
            for (sec_blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.edge_type == .normal) break :blk edge.target;
            }
            break :blk null;
        };

        // Short-circuit block should be the merge point OR lead to it
        if (sec_merge != short_id and sec_merge != null) {
            // Check if both go to same place
            const short_blk = &self.cfg.blocks[short_id];
            const short_merge = blk: {
                for (short_blk.successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    if (edge.edge_type == .normal) break :blk edge.target;
                }
                break :blk null;
            };
            if (sec_merge != short_merge) return null;
        }

        return BoolOpPattern{
            .condition_block = block_id,
            .second_block = sec_id,
            .merge_block = short_id,
            .is_and = is_and,
            .kind = kind,
        };
    }

    /// Check if an opcode is a conditional jump.
    pub fn isCondJump(opcode: Opcode) bool {
        return switch (opcode) {
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
            .JUMP_IF_TRUE_OR_POP,
            .JUMP_IF_FALSE_OR_POP,
            .JUMP_IF_TRUE, // Python 3.0
            .JUMP_IF_FALSE, // Python 3.0
            .JUMP_IF_NOT_EXC_MATCH,
            => true,
            else => false,
        };
    }

    pub fn isConditionalJump(_: *const Analyzer, opcode: Opcode) bool {
        return Analyzer.isCondJump(opcode);
    }

    fn hasStmtPrelude(block: *const BasicBlock) bool {
        for (block.instructions) |inst| {
            if (Analyzer.isCondJump(inst.opcode)) break;
            const name = inst.opcode.name();
            if (std.mem.startsWith(u8, name, "STORE_") or
                std.mem.startsWith(u8, name, "DELETE_") or
                std.mem.startsWith(u8, name, "IMPORT_") or
                std.mem.startsWith(u8, name, "RETURN_") or
                std.mem.startsWith(u8, name, "RAISE_") or
                std.mem.startsWith(u8, name, "YIELD_") or
                std.mem.eql(u8, name, "POP_TOP"))
            {
                return true;
            }
        }
        return false;
    }

    fn elifPredOk(self: *Analyzer, cond_id: u32, else_id: u32, else_jump: ?u32) bool {
        if (else_id >= self.cfg.blocks.len) return false;
        const else_blk = &self.cfg.blocks[else_id];
        if (else_blk.predecessors.len == 1 and else_blk.predecessors[0] == cond_id) return true;
        if (else_jump) |jid| {
            if (jid >= self.cfg.blocks.len) return false;
            if (else_blk.predecessors.len != 1 or else_blk.predecessors[0] != jid) return false;
            const jump_blk = &self.cfg.blocks[jid];
            if (jump_blk.predecessors.len != 1 or jump_blk.predecessors[0] != cond_id) return false;
            if (cfg_mod.jumpTargetIfJumpOnly(self.cfg, jid, true) != else_id) return false;
            return true;
        }
        return false;
    }

    /// Detect if/elif/else pattern.
    fn detectIfPattern(self: *Analyzer, block_id: u32) !?IfPattern {
        const block = &self.cfg.blocks[block_id];

        // Need exactly two non-exception successors for a conditional
        var non_exc_edges: [2]Edge = undefined;
        var non_exc_len: usize = 0;
        for (block.successors) |edge| {
            if (edge.edge_type == .exception) continue;
            if (non_exc_len < non_exc_edges.len) {
                non_exc_edges[non_exc_len] = edge;
            }
            non_exc_len += 1;
        }
        if (non_exc_len != 2) return null;

        var then_block: ?u32 = null;
        var else_block: ?u32 = null;

        // Identify then and else blocks based on edge types
        for (non_exc_edges[0..2]) |edge| {
            switch (edge.edge_type) {
                .conditional_false => else_block = edge.target,
                .conditional_true, .normal => {
                    if (then_block == null) then_block = edge.target;
                },
                else => {},
            }
        }

        // For POP_JUMP_IF_FALSE/JUMP_IF_FALSE, fallthrough is the then-block
        const term = block.terminator() orelse return null;
        if (term.opcode == .POP_JUMP_IF_FALSE or
            term.opcode == .POP_JUMP_IF_NONE or
            term.opcode == .POP_JUMP_FORWARD_IF_FALSE or
            term.opcode == .POP_JUMP_FORWARD_IF_NONE or
            term.opcode == .POP_JUMP_BACKWARD_IF_FALSE or
            term.opcode == .POP_JUMP_BACKWARD_IF_NONE or
            term.opcode == .JUMP_IF_FALSE) // Python 3.0
        {
            // Jump target is else, fallthrough is then
            for (non_exc_edges[0..2]) |edge| {
                if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                    then_block = edge.target;
                } else if (edge.edge_type == .conditional_false) {
                    else_block = edge.target;
                }
            }
        }

        var else_jump: ?u32 = null;
        if (else_block) |else_id| {
            if (cfg_mod.jumpTargetIfJumpOnly(self.cfg, else_id, true)) |target| {
                else_jump = else_id;
                else_block = target;
            }
        }

        const then_id = then_block orelse return null;
        var join_merge: ?u32 = null;
        if (else_block) |else_id| {
            var join_pred = false;
            if (else_id < self.cfg.blocks.len and block_id < self.cfg.blocks.len) {
                const cond_off = self.cfg.blocks[block_id].start_offset;
                for (self.cfg.blocks[else_id].predecessors) |pred_id| {
                    if (pred_id == block_id or pred_id >= self.cfg.blocks.len) continue;
                    const pred_blk = &self.cfg.blocks[pred_id];
                    if (cfg_mod.jumpTargetIfJumpOnly(self.cfg, pred_id, true) != null) continue;
                    if (pred_blk.terminator()) |pred_term| {
                        if (self.isConditionalJump(pred_term.opcode)) continue;
                    }
                    var has_edge = false;
                    for (pred_blk.successors) |edge| {
                        if (edge.target != else_id) continue;
                        if (edge.edge_type == .exception or edge.edge_type == .loop_back) continue;
                        has_edge = true;
                        break;
                    }
                    if (!has_edge) continue;
                    if (try self.reachesBlock(then_id, pred_id, cond_off)) {
                        join_pred = true;
                        break;
                    }
                }
            }
            if (join_pred) {
                join_merge = else_id;
                else_block = null;
            }
        }
        const then_terminal = self.isTerminalBlock(then_id);
        const then_is_raise = blk: {
            var tid = then_id;
            if (self.jumpOnlyTarget(tid)) |tgt| tid = tgt;
            if (tid >= self.cfg.blocks.len) break :blk false;
            const blk_ = &self.cfg.blocks[tid];
            for (blk_.instructions) |inst| {
                if (inst.opcode == .RAISE_VARARGS or inst.opcode == .RERAISE) break :blk true;
            }
            break :blk false;
        };

        const is_skip = struct {
            fn check(op: Opcode) bool {
                return switch (op) {
                    .CACHE, .NOP, .NOT_TAKEN => true,
                    else => false,
                };
            }
        }.check;

        const is_uncond = struct {
            fn check(op: Opcode) bool {
                return op == .JUMP_FORWARD or op == .JUMP_ABSOLUTE or op == .JUMP_BACKWARD or op == .JUMP_BACKWARD_NO_INTERRUPT;
            }
        }.check;

        const then_has_gap_jump = struct {
            fn check(self_: *Analyzer, then_id_: u32, else_id_: u32) bool {
                if (then_id_ >= self_.cfg.blocks.len or else_id_ >= self_.cfg.blocks.len) return false;
                var off = self_.cfg.blocks[then_id_].end_offset;
                while (off < self_.cfg.blocks[self_.cfg.blocks.len - 1].end_offset) {
                    const bid = self_.cfg.blockAtOffset(off) orelse return false;
                    if (bid >= self_.cfg.blocks.len) return false;
                    const blk = &self_.cfg.blocks[bid];
                    var op: ?Opcode = null;
                    for (blk.instructions) |inst| {
                        if (is_skip(inst.opcode)) continue;
                        op = inst.opcode;
                        break;
                    }
                    if (op == null) {
                        off = blk.end_offset;
                        continue;
                    }
                    if (bid == else_id_) return false;
                    return is_uncond(op.?);
                }
                return false;
            }
        }.check;

        // Find merge point - where both branches converge
        var merge = try self.findMergePoint(block_id, then_id, else_block);
        if (join_merge) |mid| {
            merge = mid;
        }

        // Check if else block is actually an elif
        var is_elif = false;
        if (else_block) |else_id| {
            const merge_id = merge;
            if (merge_id == null or merge_id.? != else_id) {
                const else_blk = &self.cfg.blocks[else_id];
                if (else_blk.terminator()) |else_term| {
                    const is_boolop_jump = else_term.opcode == .JUMP_IF_FALSE_OR_POP or
                        else_term.opcode == .JUMP_IF_TRUE_OR_POP;
                    const is_and_or = self.detectAndOr(else_id) != null;
                    if (self.isConditionalJump(else_term.opcode) and !is_boolop_jump and !is_and_or and !hasStmtPrelude(else_blk) and
                        !self.hasTrySetup(else_blk) and
                        self.elifPredOk(block_id, else_id, else_jump))
                    {
                        // If else branch can reach then-block, it's not an elif chain.
                        var reaches_then = false;
                        var seen = self.scratchSeen();
                        var queue = self.scratchQueue();
                        try queue.append(self.allocator, else_id);
                        while (queue.items.len > 0 and !reaches_then) {
                            const bid = queue.items[queue.items.len - 1];
                            queue.items.len -= 1;
                            if (bid >= self.cfg.blocks.len) continue;
                            if (seen.isSet(bid)) continue;
                            seen.set(bid);
                            if (bid == then_id) {
                                reaches_then = true;
                                break;
                            }
                            const blk = &self.cfg.blocks[bid];
                            for (blk.successors) |edge| {
                                if (edge.edge_type == .exception or edge.edge_type == .loop_back) continue;
                                if (edge.target >= self.cfg.blocks.len) continue;
                                if (!seen.isSet(edge.target)) {
                                    try queue.append(self.allocator, edge.target);
                                }
                            }
                        }
                        if (!reaches_then) {
                            // For guard-style `if cond: raise` followed by unrelated control
                            // flow, treat the else-block as the next statement (not an elif)
                            // unless the bytecode contains the usual unreachable jump gap.
                            if (!then_is_raise or then_has_gap_jump(self, then_id, else_id)) {
                                is_elif = true;
                            }
                        }
                    }
                }
            }
        }
        if (!is_elif and !then_terminal) {
            if (else_block) |else_id| {
                if (merge != null and merge.? == else_id) {
                    const else_blk = &self.cfg.blocks[else_id];
                    if (else_blk.terminator()) |else_term| {
                        const is_boolop_jump = else_term.opcode == .JUMP_IF_FALSE_OR_POP or
                            else_term.opcode == .JUMP_IF_TRUE_OR_POP;
                        if (self.isConditionalJump(else_term.opcode) and !is_boolop_jump and !hasStmtPrelude(else_blk) and
                            !self.hasTrySetup(else_blk) and
                            self.elifPredOk(block_id, else_id, else_jump))
                        {
                            const cond_off = self.cfg.blocks[block_id].start_offset;
                            if (else_blk.start_offset > cond_off) {
                                is_elif = true;
                                merge = null;
                            }
                        }
                    }
                }
            }
        }
        if (is_elif) {
            if (then_id < self.cfg.blocks.len) {
                const then_blk = &self.cfg.blocks[then_id];
                if (then_blk.terminator()) |then_term| {
                    if (self.isConditionalJump(then_term.opcode) and hasStmtPrelude(then_blk)) {
                        is_elif = false;
                    }
                }
            }
        }
        if (is_elif and merge != null and merge.? == then_id) {
            merge = null;
        }

        return IfPattern{
            .condition_block = block_id,
            .then_block = then_id,
            .else_block = else_block,
            .merge_block = merge,
            .is_elif = is_elif,
        };
    }

    pub fn detectIfOnly(self: *Analyzer, block_id: u32) !?IfPattern {
        return self.detectIfPattern(block_id);
    }

    /// Detect while loop pattern.
    fn detectWhilePattern(self: *Analyzer, block_id: u32, in_loop_context: bool) ?WhilePattern {
        const block = &self.cfg.blocks[block_id];
        if (!block.is_loop_header) return null;

        const term = block.terminator() orelse return null;
        if (!self.isConditionalJump(term.opcode)) return null;

        // Find body and exit blocks
        var body_block: ?u32 = null;
        var exit_block: ?u32 = null;

        for (block.successors) |edge| {
            if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                body_block = edge.target;
            } else if (edge.edge_type == .conditional_false) {
                exit_block = edge.target;
            }
        }

        var body_id = body_block orelse return null;
        var exit_id = exit_block orelse return null;

        const body_in_loop = self.inLoop(body_id, block_id);
        const exit_in_loop = self.inLoop(exit_id, block_id);
        if (!body_in_loop and exit_in_loop) {
            const tmp = body_id;
            body_id = exit_id;
            exit_id = tmp;
        }

        if (!self.inLoop(body_id, block_id)) return null;

        // If body block's only path forward goes through the exit block, this is
        // a guard inside while True:, not a conditional while. E.g.:
        //   while True:
        //     if guard: os._exit()  # body goes to exit, not back to header
        //     ...
        // The body (os._exit) doesn't return, but bytecode still has successor.
        // Detect this by checking if body's ONLY non-exception successor IS the exit block.
        // Note: for while A and B:, body (second condition) has exit as one branch but
        // also has the real body as another branch - don't reject those.
        const body_blk = &self.cfg.blocks[body_id];
        var body_only_to_exit = true;
        var has_non_exc_succ = false;
        for (body_blk.successors) |edge| {
            if (edge.edge_type == .exception) continue;
            has_non_exc_succ = true;
            if (edge.target != exit_id) {
                body_only_to_exit = false;
                break;
            }
        }
        if (has_non_exc_succ and body_only_to_exit) return null;

        if (self.inLoop(exit_id, block_id)) {
            const chain_blk = &self.cfg.blocks[exit_id];
            const chain_term = chain_blk.terminator() orelse return null;

            // If exit has no conditional, it's not a chained condition
            if (!self.isConditionalJump(chain_term.opcode)) {
                // Check for nested loop: exit is structured code (outer loop body)
                // that eventually loops back. Accept as valid exit.
                var has_structure = false;
                for (chain_blk.successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    if (edge.target != block_id and self.inLoop(edge.target, block_id)) {
                        has_structure = true;
                        break;
                    }
                }
                if (!has_structure) return null;
                // Accept exit_id as is - it's outer loop body
            } else {
                var chain_in: ?u32 = null;
                var chain_out: ?u32 = null;
                var any_direct_to_header = false;
                for (chain_blk.successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    if (edge.target == block_id) any_direct_to_header = true;
                    if (self.inLoop(edge.target, block_id)) {
                        chain_in = edge.target;
                    } else {
                        chain_out = edge.target;
                    }
                }
                // Nested loop case: exit_id is part of an outer loop that also
                // targets this header. All successors are in the loop but none
                // directly targets the header - this is outer loop body, not a
                // chained condition. Accept exit_id as valid exit.
                if (chain_out == null and !any_direct_to_header) {
                    // This is a nested loop situation - accept exit_id as is
                } else {
                    if (chain_in == null or chain_out == null) return null;
                    if (chain_in.? != body_id) return null;
                    if (self.inLoop(chain_out.?, block_id)) return null;
                    exit_id = chain_out.?;
                }
            }
        }

        // Check for nested loop: if there are back-edges to this header from
        // blocks BEFORE the inner loop structure (not counting fallthrough),
        // we have an outer loop with a separate header.
        // Return null so decompileLoopHeader handles the outer while True:.
        // Only do this when called from main decompile (not in_loop_context),
        // so that the inner loop can be detected during loop body processing.
        // Don't trigger for back-edges from blocks >= exit_id - those are
        // continuation of the same loop body after the inner while.
        if (!in_loop_context) {
            const header_block = &self.cfg.blocks[block_id];
            for (header_block.predecessors) |pred| {
                if (pred + 1 == block_id) continue; // fallthrough from previous block
                if (pred >= exit_id) continue; // back-edge from after inner while exit
                // Allow back-edges from anywhere in the loop body (body_id to exit_id)
                if (pred >= body_id and pred < exit_id) continue;
                // Check if pred is outside the inner loop body but in the outer loop
                if (self.inLoop(pred, block_id)) {
                    // Additional back-edge from outside inner loop body - nested loop
                    return null;
                }
            }
        }

        return WhilePattern{
            .header_block = block_id,
            .body_block = body_id,
            .exit_block = exit_id,
        };
    }

    fn exitLeadsToHeader(self: *Analyzer, start: u32, header: u32) bool {
        var cur = start;
        var steps: usize = 0;
        while (cur < self.cfg.blocks.len and steps < 8) : (steps += 1) {
            if (cur == header) return true;
            const blk = &self.cfg.blocks[cur];
            if (blk.terminator()) |term| {
                switch (term.opcode) {
                    .JUMP_FORWARD,
                    .JUMP_BACKWARD,
                    .JUMP_BACKWARD_NO_INTERRUPT,
                    .JUMP_ABSOLUTE,
                    => {
                        if (term.jumpTarget(self.cfg.version)) |target_off| {
                            if (self.cfg.blockAtOffset(target_off)) |target_id| {
                                if (target_id == cur) return false;
                                cur = target_id;
                                continue;
                            }
                        }
                        return false;
                    },
                    else => {},
                }
            }
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
        }
        return false;
    }

    fn reachesHeader(self: *Analyzer, start: u32, header: u32) !bool {
        if (start >= self.cfg.blocks.len) return false;
        if (start == header) return true;
        var seen = self.scratchSeen();
        var queue = self.scratchQueue();
        try queue.append(self.allocator, start);
        seen.set(start);
        while (queue.items.len > 0) {
            const cur = queue.items[queue.items.len - 1];
            queue.items.len -= 1;
            const blk = &self.cfg.blocks[cur];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                const tgt = edge.target;
                if (tgt >= self.cfg.blocks.len) continue;
                if (tgt == header) return true;
                if (seen.isSet(tgt)) continue;
                seen.set(tgt);
                try queue.append(self.allocator, tgt);
            }
        }
        return false;
    }

    /// Detect for loop pattern.
    fn detectForPattern(self: *Analyzer, block_id: u32) ?ForPattern {
        const block = &self.cfg.blocks[block_id];
        const term = block.terminator() orelse return null;

        if (term.opcode != .FOR_ITER and term.opcode != .FOR_LOOP) return null;

        // FOR_ITER has two successors: body (fallthrough) and exit (jump)
        var body_block: ?u32 = null;
        var exit_block: ?u32 = null;

        for (block.successors) |edge| {
            if (edge.edge_type == .normal) {
                body_block = edge.target;
            } else if (edge.edge_type == .conditional_false) {
                exit_block = edge.target;
            }
        }

        // Look backwards for GET_ITER in predecessor chain
        var setup_block: u32 = block_id;
        if (term.opcode == .FOR_LOOP) {
            // FOR_LOOP (Python 1.x-2.2): predecessor has sequence + index setup
            if (block.predecessors.len > 0) {
                setup_block = block.predecessors[0];
            }
        } else if (block.predecessors.len > 0) {
            // Trace back through predecessors to find GET_ITER
            // Python 3.14: GET_ITER may be multiple blocks back due to inline comprehension setup
            var visited = if (std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len)) |v| v else |_| return null;
            defer visited.deinit();
            var work: std.ArrayListUnmanaged(u32) = .{};
            defer work.deinit(self.allocator);

            // Start with direct predecessors (skip loop_back edges)
            for (block.predecessors) |pred_id| {
                if (pred_id >= self.cfg.blocks.len) continue;
                if (self.inLoop(pred_id, block_id)) continue;
                const pred = &self.cfg.blocks[pred_id];
                var is_loop_back = false;
                for (pred.successors) |edge| {
                    if (edge.target == block_id and edge.edge_type == .loop_back) {
                        is_loop_back = true;
                        break;
                    }
                }
                if (is_loop_back) continue;
                if (work.append(self.allocator, pred_id)) |_| {} else |_| return null;
            }

            outer: while (work.items.len > 0) {
                const cur_id = work.pop().?;
                if (cur_id >= self.cfg.blocks.len) continue;

                if (visited.isSet(cur_id)) continue;
                visited.set(cur_id);

                const cur = &self.cfg.blocks[cur_id];

                // Check if this block has GET_ITER
                for (cur.instructions) |inst| {
                    if (inst.opcode == .GET_ITER) {
                        setup_block = cur_id;
                        break :outer;
                    }
                }

                // Add predecessors to worklist (only normal flow)
                for (cur.predecessors) |pred_id| {
                    if (pred_id >= self.cfg.blocks.len) continue;
                    if (self.inLoop(pred_id, block_id)) continue;
                    const pred = &self.cfg.blocks[pred_id];
                    var is_loop_back = false;
                    for (pred.successors) |edge| {
                        if (edge.target == cur_id and edge.edge_type == .loop_back) {
                            is_loop_back = true;
                            break;
                        }
                    }
                    if (is_loop_back) continue;
                    if (!visited.isSet(pred_id)) {
                        if (work.append(self.allocator, pred_id)) |_| {} else |_| return null;
                    }
                }
            }
        }

        var setup_tail: ?u32 = null;
        var body_id = body_block orelse return null;
        if (body_id < self.cfg.blocks.len) {
            const body_blk = &self.cfg.blocks[body_id];
            if (body_blk.instructions.len == 1 and (body_blk.instructions[0].opcode == .SETUP_WITH or body_blk.instructions[0].opcode == .SETUP_ASYNC_WITH)) {
                setup_tail = body_id;
                var next_body: ?u32 = null;
                for (body_blk.successors) |edge| {
                    if (edge.edge_type == .normal) {
                        next_body = edge.target;
                        break;
                    }
                }
                if (next_body == null) return null;
                body_id = next_body.?;
            }
        }
        var exit_id = exit_block orelse return null;
        var else_id: ?u32 = null;

        if (self.dom.num_blocks > 0) {
            if (self.loopRegion(block_id) orelse self.dom.getLoopBody(block_id)) |body_set| {
                var break_target: ?u32 = null;
                var multi = false;
                var it = body_set.iterator(.{});
                while (it.next()) |idx| {
                    const bid: u32 = @intCast(idx);
                    if (bid >= self.cfg.blocks.len) continue;
                    const blk = &self.cfg.blocks[bid];
                    if (blk.is_exception_handler) continue;
                    for (blk.successors) |edge| {
                        if (edge.edge_type == .exception) continue;
                        const exit_info = self.resolveExitTarget(edge.target);
                        if (!exit_info.jumped) continue;
                        const tgt = exit_info.id;
                        if (tgt >= self.cfg.blocks.len) continue;
                        if (body_set.isSet(@intCast(tgt))) continue;
                        if (tgt == exit_id) continue;
                        if (break_target == null) {
                            break_target = tgt;
                        } else if (break_target.? != tgt) {
                            multi = true;
                            break;
                        }
                    }
                    if (multi) break;
                }
                if (!multi and break_target != null) {
                    const exit_blk = &self.cfg.blocks[exit_id];
                    var only_from_header = true;
                    for (exit_blk.predecessors) |pred_id| {
                        if (pred_id != block_id) {
                            only_from_header = false;
                            break;
                        }
                    }
                    if (only_from_header) {
                        else_id = exit_id;
                        exit_id = break_target.?;
                    }
                }
            }
        }

        return ForPattern{
            .setup_block = setup_block,
            .header_block = block_id,
            .body_block = body_id,
            .else_block = else_id,
            .exit_block = exit_id,
        };
    }

    /// Detect try/except/finally pattern.
    fn detectTryPattern(self: *Analyzer, block_id: u32) !?TryPattern {
        if (block_id >= self.cfg.blocks.len) return null;
        if (self.try_cache_checked.isSet(block_id)) {
            return self.try_cache[block_id];
        }
        self.try_cache_checked.set(block_id);
        const block = &self.cfg.blocks[block_id];
        if (block.is_exception_handler) return null;

        var has_setup = false;
        var has_setup_except = false;
        var has_setup_finally = false;
        var setup_finally_target: ?u32 = null;
        const setup_multiplier: u32 = if (self.cfg.version.gte(3, 10)) 2 else 1;
        if (!self.cfg.version.gte(3, 11)) {
            for (block.instructions) |inst| {
                if (inst.opcode == .SETUP_EXCEPT) {
                    has_setup = true;
                    has_setup_except = true;
                } else if (inst.opcode == .SETUP_FINALLY) {
                    has_setup = true;
                    has_setup_finally = true;
                    if (setup_finally_target == null) {
                        const target_off = inst.offset + inst.size + inst.arg * setup_multiplier;
                        if (self.cfg.blockAtOffset(target_off)) |target_id| {
                            setup_finally_target = target_id;
                        }
                    }
                }
            }
            if (!has_setup) return null;
        }

        var handler_targets: std.ArrayListUnmanaged(u32) = .{};
        defer handler_targets.deinit(self.allocator);

        if (!self.cfg.version.gte(3, 11)) {
            for (block.instructions) |inst| {
                if (inst.opcode != .SETUP_EXCEPT and inst.opcode != .SETUP_FINALLY) continue;
                const target_off = inst.offset + inst.size + inst.arg * setup_multiplier;
                if (self.cfg.blockAtOffset(target_off)) |target_id| {
                    var seen = false;
                    for (handler_targets.items) |existing| {
                        if (existing == target_id) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) {
                        try handler_targets.append(self.allocator, target_id);
                    }
                }
            }
        }
        if (handler_targets.items.len == 0) {
            try self.collectExceptionTargets(block_id, &handler_targets);
        }
        if (handler_targets.items.len == 0) return null;
        if (!self.cfg.version.gte(3, 11)) {
            var idx: usize = 0;
            while (idx < handler_targets.items.len) : (idx += 1) {
                const hid = handler_targets.items[idx];
                if (hid >= self.cfg.blocks.len) continue;
                const hblk = &self.cfg.blocks[hid];
                const term = hblk.terminator() orelse continue;
                if (term.opcode == .JUMP_IF_NOT_EXC_MATCH or
                    term.opcode == .JUMP_IF_FALSE or term.opcode == .POP_JUMP_IF_FALSE)
                {
                    if (term.jumpTarget(self.cfg.version)) |target_off| {
                        if (self.cfg.blockAtOffset(target_off)) |target_id| {
                            var next_id = target_id;
                            if (self.jumpOnlyTarget(next_id)) |jump_id| {
                                next_id = jump_id;
                            }
                            if (next_id < self.cfg.blocks.len) {
                                const next_blk = &self.cfg.blocks[next_id];
                                if (self.hasExceptionTypeCheck(next_blk)) {
                                    var seen = false;
                                    for (handler_targets.items) |existing| {
                                        if (existing == next_id) {
                                            seen = true;
                                            break;
                                        }
                                    }
                                    if (!seen) {
                                        try handler_targets.append(self.allocator, next_id);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            std.mem.sort(u32, handler_targets.items, {}, std.sort.asc(u32));
        }
        if (!self.cfg.version.gte(3, 11) and handler_targets.items.len > 1) {
            const first_handler = handler_targets.items[0];
            var reachable = self.scratchSeen();
            var queue = self.scratchQueue();
            try queue.append(self.allocator, first_handler);
            while (queue.items.len > 0) {
                const bid = queue.items[queue.items.len - 1];
                queue.items.len -= 1;
                if (bid >= self.cfg.blocks.len) continue;
                if (reachable.isSet(bid)) continue;
                reachable.set(bid);
                const blk = &self.cfg.blocks[bid];
                for (blk.successors) |edge| {
                    if (edge.edge_type == .exception) continue;
                    if (edge.target >= self.cfg.blocks.len) continue;
                    if (!reachable.isSet(edge.target)) {
                        try queue.append(self.allocator, edge.target);
                    }
                }
            }
            var filtered: std.ArrayListUnmanaged(u32) = .{};
            defer filtered.deinit(self.allocator);
            for (handler_targets.items) |hid| {
                if (hid < self.cfg.blocks.len and reachable.isSet(hid)) {
                    try filtered.append(self.allocator, hid);
                }
            }
            if (filtered.items.len > 0) {
                handler_targets.clearRetainingCapacity();
                try handler_targets.appendSlice(self.allocator, filtered.items);
            }
        }

        // Collect all exception handlers reachable from this block
        var handler_list: std.ArrayListUnmanaged(HandlerInfo) = .{};
        defer handler_list.deinit(self.allocator);

        for (handler_targets.items) |hid| {
            if (hid >= self.cfg.blocks.len) continue;
            const handler_block = &self.cfg.blocks[hid];
            if (self.isWithCleanupHandler(handler_block)) continue;
            // Skip generator StopIteration handlers (CALL_INTRINSIC_1 + RERAISE)
            if (self.isStopIterHandler(handler_block)) continue;
            // Skip comprehension cleanup handlers (SWAP/POP_TOP/STORE_FAST/RERAISE)
            if (self.isComprehensionCleanupHandler(handler_block)) continue;
            // Skip internal except* cleanup handlers (LIST_APPEND scaffolding)
            if (self.isExceptStarCleanupHandler(handler_block)) continue;
            const is_bare = !self.hasExceptionTypeCheck(handler_block);
            try handler_list.append(self.allocator, .{
                .handler_block = hid,
                .is_bare = is_bare,
            });
        }

        if (handler_list.items.len == 0) return null;

        // Find exit block - where control goes after all handlers
        var exit_block: ?u32 = null;
        for (handler_list.items) |handler| {
            const h_block = &self.cfg.blocks[handler.handler_block];
            for (h_block.successors) |edge| {
                if (edge.edge_type == .normal and !self.cfg.blocks[edge.target].is_exception_handler) {
                    exit_block = edge.target;
                    break;
                }
            }
            if (exit_block != null) break;
        }

        const handlers = try self.allocator.dupe(HandlerInfo, handler_list.items);

        var has_final = false;
        var has_except = false;
        for (handler_list.items) |handler| {
            if (try self.handlerIsFinally(handler.handler_block)) {
                has_final = true;
            } else {
                has_except = true;
            }
        }

        // Detect else and finally blocks
        var else_block: ?u32 = null;
        var finally_block: ?u32 = null;
        if (self.cfg.version.gte(3, 11)) {
            else_block = try self.detectElseBlock311(block_id, handler_list.items, exit_block);
            finally_block = try self.detectFinallyBlock311(block_id, handler_list.items, else_block, exit_block);
        } else {
            if (has_except) {
                else_block = try self.detectElseBlockLegacy(block_id, handler_list.items, exit_block);
            } else {
                else_block = null;
            }
            if (has_final) {
                finally_block = setup_finally_target orelse
                    try self.detectFinallyBlockLegacy(block_id, handler_list.items, else_block, exit_block);
            } else {
                finally_block = null;
            }
        }

        const pattern = TryPattern{
            .try_block = block_id,
            .handlers = handlers,
            .handlers_owned = false,
            .else_block = else_block,
            .finally_block = finally_block,
            .exit_block = exit_block,
        };
        self.try_cache[block_id] = pattern;
        return pattern;
    }

    fn isWithCleanupHandler(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .WITH_EXCEPT_START, .WITH_CLEANUP_START, .WITH_CLEANUP_FINISH => return true,
                else => {},
            }
        }
        return false;
    }

    pub fn hasExceptionHandlerOpcodes(block: *const BasicBlock) bool {
        var has_dup = false;
        var has_exc_cmp = false;
        var has_jump = false;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .PUSH_EXC_INFO, .CHECK_EXC_MATCH, .JUMP_IF_NOT_EXC_MATCH => return true,
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

    fn jumpOnlyTarget(self: *const Analyzer, block_id: u32) ?u32 {
        if (block_id >= self.cfg.blocks.len) return null;
        const blk = &self.cfg.blocks[block_id];
        if (blk.instructions.len != 1) return null;
        const inst = blk.instructions[0];
        if (inst.opcode != .JUMP_FORWARD and inst.opcode != .JUMP_ABSOLUTE) return null;
        if (inst.jumpTarget(self.cfg.version)) |target_offset| {
            if (self.cfg.blockAtOffset(target_offset)) |target_id| {
                return target_id;
            }
        }
        return null;
    }

    fn cleanupJumpTarget(self: *const Analyzer, block_id: u32) ?u32 {
        if (block_id >= self.cfg.blocks.len) return null;
        const blk = &self.cfg.blocks[block_id];
        if (blk.instructions.len == 0) return null;
        const last = blk.instructions[blk.instructions.len - 1];
        if (last.opcode != .JUMP_FORWARD and last.opcode != .JUMP_ABSOLUTE) return null;
        if (blk.instructions.len > 1) {
            for (blk.instructions[0 .. blk.instructions.len - 1]) |inst| {
                switch (inst.opcode) {
                    .POP_BLOCK, .POP_TOP, .POP_EXCEPT, .END_FINALLY, .END_FOR, .NOP => {},
                    else => return null,
                }
            }
        }
        if (last.jumpTarget(self.cfg.version)) |target_offset| {
            if (self.cfg.blockAtOffset(target_offset)) |target_id| {
                return target_id;
            }
        }
        return null;
    }

    fn resolveExitTarget(self: *const Analyzer, block_id: u32) struct { id: u32, jumped: bool } {
        var cur = block_id;
        var jumped = false;
        var steps: usize = 0;
        while (cur < self.cfg.blocks.len and steps < 8) {
            if (self.jumpOnlyTarget(cur)) |jump| {
                cur = jump;
                jumped = true;
                steps += 1;
                continue;
            }
            if (self.cleanupJumpTarget(cur)) |jump| {
                cur = jump;
                jumped = true;
                steps += 1;
                continue;
            }
            break;
        }
        return .{ .id = cur, .jumped = jumped };
    }

    fn handlerReaches(self: *Analyzer, handlers: []const HandlerInfo, target: u32) !bool {
        if (handlers.len == 0) return false;
        if (target >= self.cfg.blocks.len) return false;

        var seen = self.scratchSeen();
        var queue = self.scratchQueue();

        for (handlers) |h| {
            if (h.handler_block < self.cfg.blocks.len) {
                try queue.append(self.allocator, h.handler_block);
            }
        }

        while (queue.items.len > 0) {
            const bid = queue.items[queue.items.len - 1];
            queue.items.len -= 1;
            if (bid >= self.cfg.blocks.len) continue;
            if (seen.isSet(bid)) continue;
            seen.set(bid);
            if (bid == target) return true;
            const blk = &self.cfg.blocks[bid];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception or edge.edge_type == .loop_back) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (!seen.isSet(edge.target)) {
                    try queue.append(self.allocator, edge.target);
                }
            }
        }

        return false;
    }

    fn handlerIsFinally(self: *Analyzer, handler_block: u32) !bool {
        if (handler_block >= self.cfg.blocks.len) return false;
        const block = &self.cfg.blocks[handler_block];
        if (hasExceptionHandlerOpcodes(block)) return false;
        for (block.instructions) |inst| {
            if (inst.opcode == .CHECK_EXC_MATCH) return false;
            if (inst.opcode == .COMPARE_OP and inst.arg == 10) return false;
            if (inst.opcode == .POP_EXCEPT) return false;
        }
        for (block.instructions) |inst| {
            if (inst.opcode == .RERAISE or inst.opcode == .END_FINALLY) return true;
        }

        var seen = self.scratchSeen();
        var queue = self.scratchQueue();
        try queue.append(self.allocator, handler_block);

        while (queue.items.len > 0) {
            const bid = queue.items[queue.items.len - 1];
            queue.items.len -= 1;
            if (bid >= self.cfg.blocks.len) continue;
            if (seen.isSet(bid)) continue;
            seen.set(bid);
            const blk = &self.cfg.blocks[bid];
            for (blk.instructions) |inst| {
                if (inst.opcode == .RERAISE or inst.opcode == .END_FINALLY) return true;
            }
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception or edge.edge_type == .loop_back) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (!seen.isSet(edge.target)) {
                    try queue.append(self.allocator, edge.target);
                }
            }
        }
        return false;
    }

    /// Check if all handlers end in terminal instructions (return/raise/break)
    /// without falling through to continuation code.
    fn allHandlersTerminal(self: *Analyzer, handlers: []const HandlerInfo, exit_block: ?u32) !bool {
        if (handlers.len == 0) return false;

        for (handlers) |h| {
            if (!(try self.handlerIsTerminal(h.handler_block, exit_block))) {
                return false;
            }
        }
        return true;
    }

    /// Check if a handler block directly contains a terminal instruction (return/raise)
    /// within its own block chain, not just eventually reaching a common return path.
    /// Also treats jumps to loop exit block (break) as terminal.
    fn handlerIsTerminal(self: *Analyzer, start: u32, exit_block: ?u32) !bool {
        if (start >= self.cfg.blocks.len) return true;

        var seen = self.scratchSeen();
        var queue = self.scratchQueue();
        try queue.append(self.allocator, start);

        // Collect handler-reachable blocks
        var handler_blocks = self.scratchAux();

        while (queue.items.len > 0) {
            const bid = queue.items[queue.items.len - 1];
            queue.items.len -= 1;
            if (bid >= self.cfg.blocks.len) continue;
            if (seen.isSet(bid)) continue;
            seen.set(bid);
            handler_blocks.set(bid);

            const blk = &self.cfg.blocks[bid];
            if (blk.instructions.len == 0) continue;

            const last = blk.instructions[blk.instructions.len - 1];
            // Terminal instructions - check if this block is handler-exclusive
            if (last.opcode == .RETURN_VALUE or last.opcode == .RETURN_CONST or
                last.opcode == .RAISE_VARARGS or last.opcode == .RERAISE)
            {
                // Only count as terminal if this block has no predecessors from
                // outside the handler chain (i.e., it's exclusively handler-owned)
                var has_outside_pred = false;
                for (blk.predecessors) |pred_id| {
                    if (pred_id >= self.cfg.blocks.len) continue;
                    // If predecessor is not in handler chain and not the start, it's outside
                    if (!handler_blocks.isSet(pred_id) and pred_id != start) {
                        has_outside_pred = true;
                        break;
                    }
                }
                if (!has_outside_pred) {
                    continue; // This path is truly terminal (handler-owned)
                }
                // Terminal block is shared with non-handler path, don't count as terminal
                return false;
            }

            // Check successors
            var has_non_terminal_succ = false;
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                // Break to loop exit is terminal - treat as handler-owned terminal
                // Check both direct jump to exit and jump to where exit leads
                if (exit_block) |exit| {
                    if (edge.target == exit) {
                        // Direct jump to loop exit - handler IS terminal
                        continue;
                    }
                    // Also check if handler jumps to same destination as loop exit
                    // (e.g., both break paths go to same return block)
                    const exit_dest = self.jumpOnlyTarget(exit);
                    if (exit_dest != null and edge.target == exit_dest.?) {
                        continue;
                    }
                }
                // Loop back edges don't count as continuation
                if (edge.edge_type == .loop_back) continue;

                if (!seen.isSet(edge.target)) {
                    try queue.append(self.allocator, edge.target);
                    has_non_terminal_succ = true;
                }
            }

            // If block has no successors and isn't terminal, it falls through
            if (!has_non_terminal_succ and blk.successors.len == 0) {
                return false;
            }
        }
        return true;
    }

    /// Public version: check if all handler blocks are terminal (for decompiler)
    pub fn allHandlerBlocksTerminal(self: *Analyzer, handler_blocks: []const u32, exit_block: ?u32) !bool {
        if (handler_blocks.len == 0) return false;

        for (handler_blocks) |hid| {
            if (!(try self.handlerIsTerminal(hid, exit_block))) {
                return false;
            }
        }
        return true;
    }

    fn collectReachableNormal(self: *Analyzer, start: u32, seen: *std.DynamicBitSet) !void {
        if (start >= self.cfg.blocks.len) return;
        var queue: std.ArrayListUnmanaged(u32) = .{};
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, start);

        while (queue.items.len > 0) {
            const bid = queue.items[queue.items.len - 1];
            queue.items.len -= 1;
            if (bid >= self.cfg.blocks.len) continue;
            if (seen.isSet(bid)) continue;
            seen.set(bid);
            const blk = &self.cfg.blocks[bid];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception or edge.edge_type == .loop_back) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (!seen.isSet(edge.target)) {
                    try queue.append(self.allocator, edge.target);
                }
            }
        }
    }

    fn commonReachableNormal(self: *Analyzer, starts: []const u32) !?u32 {
        if (starts.len == 0) return null;

        var min_off: u32 = std.math.maxInt(u32);
        for (starts) |s| {
            if (s < self.cfg.blocks.len) {
                const off = self.cfg.blocks[s].start_offset;
                if (off < min_off) min_off = off;
            }
        }

        var sets = try self.allocator.alloc(std.DynamicBitSet, starts.len);
        defer {
            for (sets) |*set| set.deinit();
            self.allocator.free(sets);
        }

        for (starts, 0..) |s, i| {
            sets[i] = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
            try self.collectReachableNormal(s, &sets[i]);
        }

        var best: ?u32 = null;
        var best_off: u32 = 0;
        for (self.cfg.blocks, 0..) |*blk, id| {
            if (min_off != std.math.maxInt(u32) and blk.start_offset < min_off) continue;
            var ok = true;
            for (sets) |*set| {
                if (!set.isSet(@intCast(id))) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            if (best == null or blk.start_offset < best_off) {
                best = @intCast(id);
                best_off = blk.start_offset;
            }
        }
        return best;
    }

    fn detectElseBlock311(
        self: *Analyzer,
        try_block: u32,
        handlers: []const HandlerInfo,
        exit_block: ?u32,
    ) !?u32 {
        if (try_block >= self.cfg.blocks.len) return null;
        if (handlers.len == 0) return null;
        const first_handler = handlers[0].handler_block;

        // Find the last block in the try body (before first handler)
        var last_try_block = try_block;
        var cur = try_block;
        while (cur < first_handler) {
            const blk = &self.cfg.blocks[cur];
            var has_normal_succ = false;
            for (blk.successors) |edge| {
                if (edge.edge_type == .normal and edge.target < first_handler) {
                    has_normal_succ = true;
                    last_try_block = edge.target;
                }
            }
            if (!has_normal_succ) break;
            cur += 1;
            if (cur >= self.cfg.blocks.len) break;
        }

        // Check if last_try_block has a normal successor after all handlers
        const last_blk = &self.cfg.blocks[last_try_block];
        var candidate: ?u32 = null;
        for (last_blk.successors) |edge| {
            if (edge.edge_type != .normal) continue;
            if (edge.target <= first_handler) continue;
            // Check if target is after all handlers
            var is_after_handlers = true;
            for (handlers) |h| {
                if (edge.target == h.handler_block) {
                    is_after_handlers = false;
                    break;
                }
            }
            if (is_after_handlers) {
                candidate = edge.target;
                break;
            }
        }

        if (candidate == null) return null;
        var cand = candidate.?;
        if (self.jumpOnlyTarget(cand)) |jump| {
            if (jump == cand) return null;
            cand = jump;
        }
        const loops = self.findEnclosingLoops(try_block);
        if (loops.len > 0) {
            const header = loops[loops.len - 1];
            if (!self.inLoop(cand, header)) return null;
        }

        // Verify candidate is not reachable from any handler without going through exit
        if (try self.handlerReaches(handlers, cand)) return null;

        // Verify candidate comes before exit_block
        if (exit_block) |exit| {
            if (exit > try_block and cand >= exit) return null;
        }

        return candidate;
    }

    fn detectElseBlockLegacy(
        self: *Analyzer,
        try_block: u32,
        handlers: []const HandlerInfo,
        exit_block: ?u32,
    ) !?u32 {
        if (try_block >= self.cfg.blocks.len) return null;
        if (handlers.len == 0) return null;

        var first_handler: u32 = handlers[0].handler_block;
        for (handlers) |h| {
            if (h.handler_block < first_handler) first_handler = h.handler_block;
        }

        // Walk normal edges through try body (bounded before first handler)
        var try_body = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer try_body.deinit();
        var work: std.ArrayListUnmanaged(u32) = .{};
        defer work.deinit(self.allocator);
        if (try_block < first_handler) {
            try work.append(self.allocator, try_block);
        }
        while (work.items.len > 0) {
            const bid = work.pop().?;
            if (bid >= self.cfg.blocks.len) continue;
            if (bid >= first_handler) continue;
            if (try_body.isSet(bid)) continue;
            var is_handler = false;
            for (handlers) |h| {
                if (bid == h.handler_block) {
                    is_handler = true;
                    break;
                }
            }
            if (is_handler) continue;
            try_body.set(bid);
            const blk = &self.cfg.blocks[bid];
            for (blk.successors) |edge| {
                if (edge.edge_type != .normal and edge.edge_type != .loop_back) continue;
                if (edge.target >= first_handler) continue;
                var tgt_is_handler = false;
                for (handlers) |h| {
                    if (edge.target == h.handler_block) {
                        tgt_is_handler = true;
                        break;
                    }
                }
                if (tgt_is_handler) continue;
                if (!try_body.isSet(edge.target)) {
                    try work.append(self.allocator, edge.target);
                }
            }
        }

        // Candidate else block is a normal successor leaving the try body
        var candidate: ?u32 = null;
        var best_off: u32 = std.math.maxInt(u32);
        var bid: u32 = 0;
        while (bid < self.cfg.blocks.len) : (bid += 1) {
            if (!try_body.isSet(bid)) continue;
            const blk = &self.cfg.blocks[bid];
            for (blk.successors) |edge| {
                if (edge.edge_type != .normal and edge.edge_type != .loop_back) continue;
                if (edge.target <= first_handler) continue;
                var is_handler = false;
                for (handlers) |h| {
                    if (edge.target == h.handler_block) {
                        is_handler = true;
                        break;
                    }
                }
                if (is_handler) continue;
                const off = self.cfg.blocks[edge.target].start_offset;
                if (off < best_off) {
                    best_off = off;
                    candidate = edge.target;
                }
            }
        }
        if (candidate == null) return null;
        var cand = candidate.?;
        if (self.jumpOnlyTarget(cand)) |jump| {
            if (jump == cand) return null;
            cand = jump;
        }
        const loops = self.findEnclosingLoops(try_block);
        if (loops.len > 0) {
            const header = loops[loops.len - 1];
            if (!self.inLoop(cand, header)) return null;
        }

        // Verify not a handler
        for (handlers) |h| {
            if (cand == h.handler_block) return null;
        }

        // Verify candidate is not reachable from handlers
        if (try self.handlerReaches(handlers, cand)) return null;

        // Note: terminal handler check (allHandlersTerminal) is done in decompiler
        // where we have loop context to properly detect breaks

        // Verify candidate comes before exit
        if (exit_block) |exit| {
            if (exit > try_block and cand >= exit) return null;
        }

        // Verify candidate comes after try block
        if (cand <= try_block) return null;

        return cand;
    }

    fn detectFinallyBlock311(
        self: *Analyzer,
        try_block: u32,
        handlers: []const HandlerInfo,
        else_block: ?u32,
        exit_block: ?u32,
    ) !?u32 {
        if (try_block >= self.cfg.blocks.len) return null;
        if (handlers.len == 0) return null;

        // In 3.11+, finally is a common successor of:
        // - try body normal path
        // - else block normal path (if present)
        // - all exception handlers

        // Collect candidates from try/else normal exits
        var candidates: std.ArrayListUnmanaged(u32) = .{};
        defer candidates.deinit(self.allocator);

        // Start with try body's normal successor
        const try_blk = &self.cfg.blocks[try_block];
        for (try_blk.successors) |edge| {
            if (edge.edge_type == .normal) {
                try candidates.append(self.allocator, edge.target);
            }
        }

        // If else exists, use its successors
        if (else_block) |eb| {
            candidates.clearRetainingCapacity();
            if (eb < self.cfg.blocks.len) {
                const else_blk = &self.cfg.blocks[eb];
                for (else_blk.successors) |edge| {
                    if (edge.edge_type == .normal) {
                        try candidates.append(self.allocator, edge.target);
                    }
                }
            }
        }

        // Add handler normal exits
        for (handlers) |h| {
            if (h.handler_block >= self.cfg.blocks.len) continue;
            const h_blk = &self.cfg.blocks[h.handler_block];
            for (h_blk.successors) |edge| {
                if (edge.edge_type == .normal) {
                    var exists = false;
                    for (candidates.items) |c| {
                        if (c == edge.target) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) try candidates.append(self.allocator, edge.target);
                }
            }
        }

        if (candidates.items.len == 0) return null;

        const common = try self.commonReachableNormal(candidates.items);
        if (common == null) return null;
        var candidate = common.?;

        // If we only found the try body's entry, try to find the normal-path finally block
        // via POP_BLOCK that unwinds to one of the handlers.
        var try_entry: ?u32 = null;
        for (try_blk.successors) |edge| {
            if (edge.edge_type == .normal) {
                try_entry = edge.target;
                break;
            }
        }
        if (candidate == try_block or (try_entry != null and candidate == try_entry.?)) {
            var cleanup_candidate: ?u32 = null;
            for (self.cfg.blocks) |*blk| {
                if (blk.instructions.len != 1) continue;
                if (blk.instructions[0].opcode != .POP_BLOCK) continue;
                var has_exc = false;
                var normal_target: ?u32 = null;
                var multi = false;
                for (blk.successors) |edge| {
                    if (edge.edge_type == .exception) {
                        for (handlers) |h| {
                            if (edge.target == h.handler_block) {
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
                for (handlers) |h| {
                    if (normal_target.? == h.handler_block) {
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
                candidate = cand;
            }
        }

        // Verify not a handler
        for (handlers) |h| {
            if (candidate == h.handler_block) return null;
        }

        // Verify not the else block
        if (else_block) |eb| {
            if (candidate == eb) return null;
        }

        // Verify comes before exit
        if (exit_block) |exit| {
            if (candidate >= exit) return null;
        }

        return candidate;
    }

    fn detectFinallyBlockLegacy(
        self: *Analyzer,
        try_block: u32,
        handlers: []const HandlerInfo,
        else_block: ?u32,
        exit_block: ?u32,
    ) !?u32 {
        if (try_block >= self.cfg.blocks.len) return null;
        if (handlers.len == 0) return null;

        // Collect all paths that should reach finally:
        // 1. Normal exit from try body
        // 2. Normal exit from else block (if present)
        // 3. Normal exit from each handler

        var candidates: std.ArrayListUnmanaged(u32) = .{};
        defer candidates.deinit(self.allocator);

        // Add try body normal successor
        const try_blk = &self.cfg.blocks[try_block];
        for (try_blk.successors) |edge| {
            if (edge.edge_type == .normal) {
                try candidates.append(self.allocator, edge.target);
            }
        }

        // If else exists, use its successors instead of try's
        if (else_block) |eb| {
            candidates.clearRetainingCapacity();
            if (eb < self.cfg.blocks.len) {
                const else_blk = &self.cfg.blocks[eb];
                for (else_blk.successors) |edge| {
                    if (edge.edge_type == .normal) {
                        try candidates.append(self.allocator, edge.target);
                    }
                }
            }
        }

        // Add handler exits
        for (handlers) |h| {
            if (h.handler_block >= self.cfg.blocks.len) continue;
            const h_blk = &self.cfg.blocks[h.handler_block];
            for (h_blk.successors) |edge| {
                if (edge.edge_type == .normal and !self.cfg.blocks[edge.target].is_exception_handler) {
                    var exists = false;
                    for (candidates.items) |c| {
                        if (c == edge.target) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) try candidates.append(self.allocator, edge.target);
                }
            }
        }

        if (candidates.items.len == 0) return null;

        const common = try self.commonReachableNormal(candidates.items);
        if (common == null) return null;
        var candidate = common.?;

        // Skip blocks ending with terminal instructions (inlined finally with return/raise)
        // These are duplicated finally code before early returns, not the actual finally
        while (candidate < self.cfg.blocks.len) {
            const cand_blk = &self.cfg.blocks[candidate];
            if (cand_blk.instructions.len > 0) {
                const last = cand_blk.instructions[cand_blk.instructions.len - 1];
                if (last.opcode == .RETURN_VALUE or last.opcode == .RETURN_CONST or
                    last.opcode == .RAISE_VARARGS or last.opcode == .RERAISE)
                {
                    // Find next reachable block that's not terminal
                    var next: ?u32 = null;
                    for (cand_blk.successors) |edge| {
                        if (edge.edge_type == .normal) {
                            next = edge.target;
                            break;
                        }
                    }
                    if (next) |n| {
                        candidate = n;
                        continue;
                    }
                    // Try to find next block by offset
                    candidate += 1;
                    continue;
                }
            }
            break;
        }
        if (candidate >= self.cfg.blocks.len) return null;

        // Verify not a handler
        for (handlers) |h| {
            if (candidate == h.handler_block) return null;
        }

        // Verify not the else block
        if (else_block) |eb| {
            if (candidate == eb) return null;
        }

        // Verify comes before exit
        if (exit_block) |exit| {
            if (candidate >= exit) return null;
        }

        return candidate;
    }

    fn edgeTypeTo(self: *Analyzer, pred_id: u32, target_id: u32) ?EdgeType {
        if (pred_id >= self.cfg.blocks.len) return null;
        const pred = &self.cfg.blocks[pred_id];
        for (pred.successors) |edge| {
            if (edge.target == target_id) return edge.edge_type;
        }
        return null;
    }

    fn collectExceptionTargets(
        self: *Analyzer,
        block_id: u32,
        targets: *std.ArrayListUnmanaged(u32),
    ) !void {
        targets.clearRetainingCapacity();
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        for (block.successors) |edge| {
            if (edge.edge_type != .exception) continue;
            var seen = false;
            for (targets.items) |existing| {
                if (existing == edge.target) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                try targets.append(self.allocator, edge.target);
            }
        }

        std.mem.sort(u32, targets.items, {}, std.sort.asc(u32));
    }

    /// Check if handler is a generator StopIteration handler (CALL_INTRINSIC_1 + RERAISE).
    fn isStopIterHandler(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        var has_intrinsic = false;
        var has_reraise = false;
        for (block.instructions) |inst| {
            if (inst.opcode == .CALL_INTRINSIC_1) has_intrinsic = true;
            if (inst.opcode == .RERAISE) has_reraise = true;
        }
        return has_intrinsic and has_reraise;
    }

    /// Check if handler is a comprehension cleanup handler (Python 3.12+).
    /// Pattern: SWAP, POP_TOP, SWAP, STORE_FAST+, RERAISE
    fn isComprehensionCleanupHandler(self: *const Analyzer, block: *const BasicBlock) bool {
        if (!self.cfg.version.gte(3, 12)) return false;
        const insts = block.instructions;
        if (insts.len < 3) return false;

        // Must end with RERAISE
        if (insts[insts.len - 1].opcode != .RERAISE) return false;

        // Must have STORE_FAST before RERAISE (restoring saved variable)
        var has_store = false;
        var i = insts.len - 2;
        while (i > 0) : (i -= 1) {
            if (insts[i].opcode == .STORE_FAST) {
                has_store = true;
            } else if (has_store) {
                // After seeing STORE_FAST, rest should be SWAP/POP_TOP
                if (insts[i].opcode != .SWAP and insts[i].opcode != .POP_TOP) {
                    return false;
                }
            }
        }
        if (i == 0 and has_store) {
            if (insts[0].opcode != .SWAP and insts[0].opcode != .POP_TOP) {
                return false;
            }
        }

        return has_store;
    }

    /// Check if handler is internal except* cleanup scaffolding (PEP 654).
    ///
    /// These blocks appear in the exception table but don't correspond to a Python-level
    /// `except` clause. They typically append raised exceptions to a list and jump.
    fn isExceptStarCleanupHandler(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        if (block.instructions.len == 0) return false;

        var has_push_exc = false;
        var has_check = false;
        var has_list_append = false;
        var has_pop_except = false;
        var has_reraise = false;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .PUSH_EXC_INFO => has_push_exc = true,
                .CHECK_EXC_MATCH, .CHECK_EG_MATCH => has_check = true,
                .LIST_APPEND => has_list_append = true,
                .POP_EXCEPT => has_pop_except = true,
                .RERAISE => has_reraise = true,
                else => {},
            }
        }
        if (has_push_exc or has_check or has_pop_except or has_reraise) return false;
        if (!has_list_append) return false;

        const last = block.instructions[block.instructions.len - 1].opcode;
        return switch (last) {
            .JUMP_FORWARD,
            .JUMP_ABSOLUTE,
            .JUMP_BACKWARD,
            .JUMP_BACKWARD_NO_INTERRUPT,
            => true,
            else => false,
        };
    }

    /// Check if handler block has exception type check (CHECK_EXC_MATCH).
    fn hasExceptionTypeCheck(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        for (block.instructions) |inst| {
            if (inst.opcode == .CHECK_EXC_MATCH) return true;
            if (inst.opcode == .COMPARE_OP and inst.arg == 10) return true;
            if (inst.opcode == .JUMP_IF_NOT_EXC_MATCH) return true;
        }
        return false;
    }

    /// Detect with statement pattern.
    fn detectWithPattern(self: *Analyzer, block_id: u32) ?WithPattern {
        const block = &self.cfg.blocks[block_id];

        // Find BEFORE_WITH/BEFORE_ASYNC_WITH/LOAD_SPECIAL or legacy SETUP_WITH
        var has_before_with = false;
        var legacy_setup: ?cfg_mod.Instruction = null;
        for (block.instructions) |inst| {
            if (inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH or inst.opcode == .LOAD_SPECIAL) {
                has_before_with = true;
                break;
            }
            if (inst.opcode == .SETUP_WITH or inst.opcode == .SETUP_ASYNC_WITH) {
                legacy_setup = inst;
                break;
            }
        }

        if (!has_before_with and legacy_setup == null) return null;

        if (!has_before_with and legacy_setup != null) {
            if (block.instructions.len == 1 and (block.instructions[0].opcode == .SETUP_WITH or block.instructions[0].opcode == .SETUP_ASYNC_WITH)) {
                if (block.predecessors.len == 1) {
                    const pred_id = block.predecessors[0];
                    if (pred_id < self.cfg.blocks.len) {
                        const pred = &self.cfg.blocks[pred_id];
                        var pred_has_before = false;
                        for (pred.instructions) |inst| {
                            if (inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH or inst.opcode == .LOAD_SPECIAL) {
                                pred_has_before = true;
                                break;
                            }
                        }
                        if (pred_has_before) return null;
                    }
                }
            }
        }

        // The body is the normal successor
        var body_block: ?u32 = null;
        var cleanup_block: ?u32 = null;

        // In Python 3.14+, exception protection starts at body, not setup
        // Setup block has LOAD_SPECIAL but no exception edge
        // Body block has the exception edge to cleanup
        for (block.successors) |edge| {
            if (edge.edge_type == .normal) {
                body_block = edge.target;
                continue;
            }
            if (edge.edge_type != .exception) continue;
            if (edge.target >= self.cfg.blocks.len) continue;
            const handler = &self.cfg.blocks[edge.target];
            for (handler.instructions) |inst| {
                if (inst.opcode == .WITH_EXCEPT_START) {
                    cleanup_block = edge.target;
                    break;
                }
            }
        }

        var setup_tail: ?u32 = null;
        var body_id = body_block orelse return null;
        if (body_id < self.cfg.blocks.len) {
            const body_blk = &self.cfg.blocks[body_id];
            if (body_blk.instructions.len == 1 and (body_blk.instructions[0].opcode == .SETUP_WITH or body_blk.instructions[0].opcode == .SETUP_ASYNC_WITH)) {
                setup_tail = body_id;
                var next_body: ?u32 = null;
                for (body_blk.successors) |edge| {
                    if (edge.edge_type == .normal) {
                        next_body = edge.target;
                        break;
                    }
                }
                if (next_body == null) return null;
                body_id = next_body.?;
            }
        }

        // If no exception edge from setup, check the body block for exception edge
        if (cleanup_block == null) {
            if (setup_tail) |tail_id| {
                const tail_blk = &self.cfg.blocks[tail_id];
                for (tail_blk.successors) |edge| {
                    if (edge.edge_type == .exception) {
                        if (edge.target < self.cfg.blocks.len) {
                            const handler = &self.cfg.blocks[edge.target];
                            for (handler.instructions) |inst| {
                                if (inst.opcode == .WITH_EXCEPT_START) {
                                    cleanup_block = edge.target;
                                    break;
                                }
                            }
                        }
                        break;
                    }
                }
            }
        }
        if (cleanup_block == null and body_id < self.cfg.blocks.len) {
            const body_blk = &self.cfg.blocks[body_id];
            for (body_blk.successors) |edge| {
                if (edge.edge_type == .exception) {
                    // Check if handler has WITH_EXCEPT_START
                    if (edge.target < self.cfg.blocks.len) {
                        const handler = &self.cfg.blocks[edge.target];
                        for (handler.instructions) |inst| {
                            if (inst.opcode == .WITH_EXCEPT_START) {
                                cleanup_block = edge.target;
                                break;
                            }
                        }
                    }
                    break;
                }
            }
        }

        // Legacy SETUP_WITH uses jump target for cleanup handler
        if (cleanup_block == null) {
            if (legacy_setup) |inst| {
                if (inst.jumpTarget(self.cfg.version)) |target| {
                    if (self.cfg.blockAtOffset(target)) |cleanup_id| {
                        cleanup_block = cleanup_id;
                    }
                }
            }
        }

        const cleanup_id = cleanup_block orelse return null;

        // Find exit block - where control goes after cleanup
        var exit_block: ?u32 = null;
        const cleanup_blk = &self.cfg.blocks[cleanup_id];
        for (cleanup_blk.successors) |edge| {
            if (edge.edge_type == .normal) {
                exit_block = edge.target;
                break;
            }
        }

        return WithPattern{
            .setup_block = block_id,
            .body_block = body_id,
            .cleanup_block = cleanup_id,
            .exit_block = exit_block orelse block_id + 1,
        };
    }

    /// Check if block looks like start of a match statement.
    /// Match starts with subject load, then MATCH_* or COPY+pattern in current or successor.
    fn isMatchSubjectBlock(self: *const Analyzer, block: *const BasicBlock) bool {
        // Check if current block has MATCH_* opcode or pattern
        if (self.hasMatchOpcode(block) or self.hasMatchPattern(block)) return true;

        // Check if successor block starts with MATCH_* or pattern
        if (block.successors.len == 0) return false;
        const succ_id = block.successors[0].target;
        if (succ_id >= self.cfg.blocks.len) return false;
        const succ = &self.cfg.blocks[succ_id];

        return self.hasMatchOpcode(succ) or self.hasMatchPattern(succ);
    }

    /// Check if block has a MATCH_* opcode.
    fn hasMatchOpcode(self: *const Analyzer, block: *const BasicBlock) bool {
        if (block.id >= self.block_flags.len) return false;
        return self.block_flags[block.id].has_match_opcode;
    }

    fn computeMatchPattern(self: *const Analyzer, block_id: u32, block: *const BasicBlock, has_match_opcode: bool) bool {
        var has_copy = false;
        var has_match_op = has_match_opcode;
        var has_cond = false;

        if (block.terminator()) |term| {
            has_cond = self.isConditionalJump(term.opcode);
        }

        for (block.instructions, 0..) |inst, i| {
            // COPY followed by STORE is class cell pattern, not match
            if (inst.opcode == .COPY) {
                const next_is_store = if (i + 1 < block.instructions.len)
                    block.instructions[i + 1].opcode == .STORE_NAME or
                        block.instructions[i + 1].opcode == .STORE_FAST
                else
                    false;
                if (!next_is_store) has_copy = true;
            }
            if (inst.opcode == .MATCH_SEQUENCE or
                inst.opcode == .MATCH_MAPPING or
                inst.opcode == .MATCH_CLASS)
            {
                has_match_op = true;
            }
            if (has_copy and inst.opcode == .COMPARE_OP) {
                has_match_op = true;
            }
        }

        if (self.cfg.version.major >= 3 and self.cfg.version.minor >= 10) {
            for (block.instructions, 0..) |inst, i| {
                if (inst.opcode == .STORE_FAST_LOAD_FAST or inst.opcode == .STORE_FAST_STORE_FAST) {
                    return has_cond or has_copy or has_match_op;
                }

                if (inst.opcode == .STORE_NAME or inst.opcode == .STORE_FAST) {
                    const has_load_before = if (i > 0)
                        block.instructions[i - 1].opcode == .LOAD_NAME or block.instructions[i - 1].opcode == .LOAD_FAST
                    else blk: {
                        if (block.predecessors.len > 0) {
                            const pred_id = block.predecessors[0];
                            if (pred_id < self.cfg.blocks.len) {
                                const pred = &self.cfg.blocks[pred_id];
                                if (pred.instructions.len > 0) {
                                    const pred_last = pred.instructions[pred.instructions.len - 1];
                                    break :blk pred_last.opcode == .LOAD_NAME or pred_last.opcode == .LOAD_FAST;
                                }
                            }
                        }
                        break :blk false;
                    };
                    if (has_load_before and (has_cond or has_copy or has_match_op)) return true;
                }
            }
        }

        _ = block_id;
        return has_copy and has_match_op;
    }

    /// Check if block has a match pattern (COPY followed by MATCH_* or literal compare).
    fn hasMatchPattern(self: *const Analyzer, block: *const BasicBlock) bool {
        if (block.id >= self.block_flags.len) return false;
        return self.block_flags[block.id].has_match_pattern;
    }

    /// Check for literal compare case without COPY (subject already on stack).
    fn isLitCaseNoCopy(self: *const Analyzer, block: *const BasicBlock) bool {
        var has_cond = false;
        if (block.terminator()) |term| {
            has_cond = self.isConditionalJump(term.opcode);
        }

        var has_copy = false;
        var has_match_op = false;
        var has_subject_load = false;
        var has_lit_cmp = false;
        var prev_get_len = false;

        const insts = block.instructions;
        var i: usize = 0;
        while (i < insts.len) : (i += 1) {
            const op = insts[i].opcode;
            if (op == .NOT_TAKEN or op == .CACHE) continue;
            switch (op) {
                .COPY => has_copy = true,
                .MATCH_SEQUENCE, .MATCH_MAPPING, .MATCH_CLASS => has_match_op = true,
                .LOAD_FAST, .LOAD_NAME, .LOAD_GLOBAL, .LOAD_DEREF => has_subject_load = true,
                .GET_LEN => {
                    prev_get_len = true;
                },
                .LOAD_CONST, .LOAD_SMALL_INT => {
                    if (!prev_get_len) {
                        var j = i + 1;
                        while (j < insts.len) : (j += 1) {
                            const next_op = insts[j].opcode;
                            if (next_op == .NOT_TAKEN or next_op == .CACHE) continue;
                            if (next_op == .COMPARE_OP) {
                                has_lit_cmp = true;
                            }
                            break;
                        }
                    }
                    prev_get_len = false;
                },
                else => prev_get_len = false,
            }
        }

        return has_cond and !has_copy and !has_match_op and !has_subject_load and has_lit_cmp;
    }

    /// Detect match statement pattern.
    fn detectMatchPattern(self: *Analyzer, block_id: u32) !?MatchPattern {
        const block = &self.cfg.blocks[block_id];

        var case_blocks: std.ArrayListUnmanaged(u32) = .{};
        defer case_blocks.deinit(self.allocator);

        // If current block has MATCH_* or pattern, it's both subject and first case
        var current: u32 = if (self.hasMatchOpcode(block) or self.hasMatchPattern(block))
            block_id
        else if (block.successors.len > 0)
            block.successors[0].target
        else
            return null;

        var exit_block: ?u32 = null;

        // Follow the chain of case blocks
        while (current < self.cfg.blocks.len) {
            const cur_block = &self.cfg.blocks[current];

            // Check if this is a case pattern block
            if (!self.hasMatchOpcode(cur_block) and !self.hasMatchPattern(cur_block) and !self.isWildcardCase(cur_block) and
                !(case_blocks.items.len > 0 and self.isLitCaseNoCopy(cur_block)))
            {
                // Not a case block - might be cleanup (POP_TOP) or exit
                // If block starts with POP_TOP, it's likely a pattern failure cleanup block
                // Skip it and check the next block (either successor or next in sequence)
                if (cur_block.instructions.len > 0 and cur_block.instructions[0].opcode == .POP_TOP) {
                    // Cleanup block - try successor, or next block if terminal
                    if (cur_block.successors.len > 0 and cur_block.successors[0].edge_type == .normal) {
                        current = cur_block.successors[0].target;
                    } else {
                        // Terminal cleanup (returns) - check next sequential block
                        current = current + 1;
                        if (current >= self.cfg.blocks.len) {
                            exit_block = null;
                            break;
                        }
                    }
                    continue;
                }
                // Otherwise, this is exit
                exit_block = current;
                break;
            }

            try case_blocks.append(self.allocator, current);

            // Find next case (false branch of conditional jump)
            var next_case: ?u32 = null;
            for (cur_block.successors) |edge| {
                if (edge.edge_type == .conditional_false) {
                    next_case = edge.target;
                    break;
                }
            }

            if (next_case) |nc| {
                current = nc;
            } else {
                // No more cases - wildcard or end
                break;
            }
        }

        if (case_blocks.items.len == 0) return null;

        const cases = try self.allocator.dupe(u32, case_blocks.items);

        return MatchPattern{
            .subject_block = block_id,
            .case_blocks = cases,
            .exit_block = exit_block,
        };
    }

    /// Check if block is a wildcard case (_).
    fn isWildcardCase(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        // Wildcard is just NOP (always matches)
        for (block.instructions) |inst| {
            if (inst.opcode == .NOP) {
                // Wildcard: no conditional jump (0 or 1 successors)
                return block.successors.len <= 1;
            }
        }
        return false;
    }

    /// Find the merge point where two branches converge.
    fn findMergePoint(self: *Analyzer, cond_block: u32, then_block: u32, else_block: ?u32) !?u32 {
        const else_id = else_block orelse return null;
        if (then_block >= self.cfg.blocks.len or else_id >= self.cfg.blocks.len) return null;
        const cond_off = if (cond_block < self.cfg.blocks.len)
            self.cfg.blocks[cond_block].start_offset
        else
            0;
        if (self.postdom.merge(then_block, else_id)) |merge| {
            if (merge >= self.cfg.blocks.len) return null;
            if (self.cfg.blocks[merge].start_offset <= cond_off) return null;
            if (self.cfg.blocks[merge].is_loop_header) return null;
            return merge;
        }

        const is_uncond = struct {
            fn check(op: Opcode) bool {
                return op == .JUMP_FORWARD or op == .JUMP_ABSOLUTE or op == .JUMP_BACKWARD or op == .JUMP_BACKWARD_NO_INTERRUPT;
            }
        }.check;

        if (self.cfg.blocks[then_block].terminator()) |term| {
            if (is_uncond(term.opcode)) {
                if (term.jumpTarget(self.cfg.version)) |target_off| {
                    if (self.cfg.blockAtOffset(target_off)) |cand| {
                        if (cand < self.cfg.blocks.len and self.cfg.blocks[cand].start_offset > cond_off and !self.cfg.blocks[cand].is_loop_header) {
                            if (try self.reachesBlock(else_id, cand, cond_off)) return cand;
                        }
                    }
                }
            }
        }

        if (self.cfg.blocks[else_id].terminator()) |term| {
            if (is_uncond(term.opcode)) {
                if (term.jumpTarget(self.cfg.version)) |target_off| {
                    if (self.cfg.blockAtOffset(target_off)) |cand| {
                        if (cand < self.cfg.blocks.len and self.cfg.blocks[cand].start_offset > cond_off and !self.cfg.blocks[cand].is_loop_header) {
                            if (try self.reachesBlock(then_block, cand, cond_off)) return cand;
                        }
                    }
                }
            }
        }

        const exit_set = struct {
            fn build(self_: *Analyzer, entry: u32, cond_off_: u32) !std.DynamicBitSet {
                var exits = try std.DynamicBitSet.initEmpty(self_.allocator, self_.cfg.blocks.len);
                if (entry >= self_.cfg.blocks.len) return exits;
                var i: u32 = 0;
                while (i < self_.cfg.blocks.len) : (i += 1) {
                    if (!self_.dom.dominates(entry, i)) continue;
                    const blk = &self_.cfg.blocks[i];
                    if (blk.start_offset <= cond_off_) continue;
                    for (blk.successors) |edge| {
                        if (edge.edge_type == .exception or edge.edge_type == .loop_back) continue;
                        const next = edge.target;
                        if (next >= self_.cfg.blocks.len) continue;
                        if (self_.cfg.blocks[next].start_offset <= cond_off_) continue;
                        if (!self_.dom.dominates(entry, next)) {
                            exits.set(next);
                        }
                    }
                }
                return exits;
            }
        };

        var then_exits = try exit_set.build(self, then_block, cond_off);
        defer then_exits.deinit();
        var else_exits = try exit_set.build(self, else_id, cond_off);
        defer else_exits.deinit();
        var best_id: ?u32 = null;
        var best_off: u32 = 0;
        var i: u32 = 0;
        while (i < self.cfg.blocks.len) : (i += 1) {
            if (!then_exits.isSet(i) or !else_exits.isSet(i)) continue;
            const blk = &self.cfg.blocks[i];
            if (blk.start_offset <= cond_off) continue;
            if (blk.is_loop_header) continue;
            const off = blk.start_offset;
            if (best_id == null or off < best_off or (off == best_off and i < best_id.?)) {
                best_id = i;
                best_off = off;
            }
        }
        if (best_id) |id| return id;
        return null;
    }

    fn reachesBlock(self: *Analyzer, start: u32, target: u32, cond_off: u32) !bool {
        if (start >= self.cfg.blocks.len or target >= self.cfg.blocks.len) return false;
        var seen = self.scratchSeen();
        var stack = self.scratchQueue();
        try stack.append(self.allocator, start);
        while (stack.items.len > 0) {
            const bid = stack.items[stack.items.len - 1];
            stack.items.len -= 1;
            if (bid >= self.cfg.blocks.len) continue;
            if (seen.isSet(bid)) continue;
            seen.set(bid);
            if (bid == target) return true;
            const blk = &self.cfg.blocks[bid];
            for (blk.successors) |edge| {
                if (edge.edge_type == .exception or edge.edge_type == .loop_back) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (self.cfg.blocks[edge.target].start_offset <= cond_off) continue;
                if (!seen.isSet(edge.target)) {
                    try stack.append(self.allocator, edge.target);
                }
            }
        }
        return false;
    }

    /// Mark a range of blocks as processed.
    pub fn markProcessed(self: *Analyzer, start: u32, end: u32) void {
        var i = start;
        while (i < end and i < self.cfg.blocks.len) : (i += 1) {
            self.processed.set(i);
        }
    }

    /// Detect if a block ends with break or continue.
    /// This requires knowing the enclosing loop(s).
    pub fn detectLoopExit(self: *Analyzer, block_id: u32, loop_headers: []const u32) LoopExit {
        if (block_id >= self.cfg.blocks.len) return .none;
        const block = &self.cfg.blocks[block_id];
        const term = block.terminator() orelse return .none;

        // Only unconditional jumps can be break/continue
        if (term.opcode != .JUMP_FORWARD and term.opcode != .JUMP_BACKWARD and term.opcode != .JUMP_BACKWARD_NO_INTERRUPT and term.opcode != .JUMP_ABSOLUTE) {
            return .none;
        }

        // Get jump target block
        if (term.jumpTarget(self.cfg.version)) |target_offset| {
            const target_block = self.cfg.blockAtOffset(target_offset) orelse return .none;

            // Check if jumping to a loop header = continue
            for (loop_headers) |header| {
                if (target_block == header) {
                    return .{ .continue_stmt = .{
                        .block = block_id,
                        .loop_header = header,
                    } };
                }
            }

            // Break if jump target leaves the innermost loop body.
            if (loop_headers.len > 0) {
                const innermost_header = loop_headers[loop_headers.len - 1];
                if (!self.inLoop(target_block, innermost_header)) {
                    return .{ .break_stmt = .{
                        .block = block_id,
                        .loop_header = innermost_header,
                    } };
                }
            }
        }

        return .none;
    }

    /// Find all loop headers that contain a given block.
    pub fn findEnclosingLoops(self: *const Analyzer, block_id: u32) []const u32 {
        if (block_id >= self.enclosing_loops.len) return &.{};
        return self.enclosing_loops[block_id].items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "analyzer init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a minimal CFG
    var blocks = try allocator.alloc(BasicBlock, 2);
    defer allocator.free(blocks);

    blocks[0] = .{
        .id = 0,
        .start_offset = 0,
        .end_offset = 4,
        .instructions = &.{},
        .successors = &.{},
        .predecessors = &.{},
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    blocks[1] = .{
        .id = 1,
        .start_offset = 4,
        .end_offset = 8,
        .instructions = &.{},
        .successors = &.{},
        .predecessors = &.{},
        .is_exception_handler = false,
        .is_loop_header = false,
    };

    const block_offsets = &[_]u32{ 0, 4 };
    var cfg_val = CFG{
        .allocator = allocator,
        .blocks = blocks,
        .block_offsets = @constCast(block_offsets),
        .entry = 0,
        .instructions = &.{},
        .exception_entries = &.{},
        .version = Version.init(3, 12),
    };

    var dom = try dom_mod.DomTree.init(allocator, &cfg_val);
    defer dom.deinit();
    var analyzer = try Analyzer.init(allocator, &cfg_val, &dom);
    defer analyzer.deinit();

    try testing.expectEqual(@as(usize, 2), cfg_val.blocks.len);
    try testing.expectEqual(@as(usize, 0), analyzer.findEnclosingLoops(0).len);
}

test "analyzer loop membership uses dom" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const version = cfg_mod.Version.init(3, 12);
    const block_offsets = &[_]u32{ 0, 10, 20, 30 };

    var succ_0 = [_]cfg_mod.Edge{.{ .target = 1, .edge_type = .normal }};
    var succ_1 = [_]cfg_mod.Edge{
        .{ .target = 2, .edge_type = .conditional_true },
        .{ .target = 3, .edge_type = .conditional_false },
    };
    var succ_2 = [_]cfg_mod.Edge{.{ .target = 1, .edge_type = .loop_back }};
    var succ_3 = [_]cfg_mod.Edge{};

    var preds_0 = [_]u32{};
    var preds_1 = [_]u32{ 0, 2 };
    var preds_2 = [_]u32{1};
    var preds_3 = [_]u32{1};

    var blocks: [4]cfg_mod.BasicBlock = undefined;
    blocks[0] = .{
        .id = 0,
        .start_offset = 0,
        .end_offset = 0,
        .instructions = &.{},
        .successors = succ_0[0..],
        .predecessors = preds_0[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    blocks[1] = .{
        .id = 1,
        .start_offset = 10,
        .end_offset = 0,
        .instructions = &.{},
        .successors = succ_1[0..],
        .predecessors = preds_1[0..],
        .is_exception_handler = false,
        .is_loop_header = true,
    };
    blocks[2] = .{
        .id = 2,
        .start_offset = 20,
        .end_offset = 0,
        .instructions = &.{},
        .successors = succ_2[0..],
        .predecessors = preds_2[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    blocks[3] = .{
        .id = 3,
        .start_offset = 30,
        .end_offset = 0,
        .instructions = &.{},
        .successors = succ_3[0..],
        .predecessors = preds_3[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };

    var cfg = cfg_mod.CFG{
        .allocator = allocator,
        .blocks = blocks[0..],
        .block_offsets = @constCast(block_offsets),
        .entry = 0,
        .instructions = &.{},
        .exception_entries = &.{},
        .version = version,
    };

    var dom = try dom_mod.DomTree.init(allocator, &cfg);
    defer dom.deinit();

    var analyzer = try Analyzer.init(allocator, &cfg, &dom);
    defer analyzer.deinit();

    const loops = analyzer.findEnclosingLoops(2);
    try testing.expectEqual(@as(usize, 1), loops.len);
    try testing.expectEqual(@as(u32, 1), loops[0]);
}

test "detectWhilePattern rejects internal exit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const version = cfg_mod.Version.init(3, 12);
    const block_offsets = &[_]u32{ 0, 2, 4 };

    const inst_0 = [_]cfg_mod.Instruction{.{
        .opcode = .POP_JUMP_IF_FALSE,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    }};

    var succ_0 = [_]cfg_mod.Edge{
        .{ .target = 1, .edge_type = .conditional_true },
        .{ .target = 2, .edge_type = .conditional_false },
    };
    var succ_1 = [_]cfg_mod.Edge{.{ .target = 2, .edge_type = .normal }};
    var succ_2 = [_]cfg_mod.Edge{.{ .target = 0, .edge_type = .loop_back }};

    var preds_0 = [_]u32{2};
    var preds_1 = [_]u32{0};
    var preds_2 = [_]u32{ 0, 1 };

    var blocks: [3]cfg_mod.BasicBlock = undefined;
    blocks[0] = .{
        .id = 0,
        .start_offset = 0,
        .end_offset = 2,
        .instructions = inst_0[0..],
        .successors = succ_0[0..],
        .predecessors = preds_0[0..],
        .is_exception_handler = false,
        .is_loop_header = true,
    };
    blocks[1] = .{
        .id = 1,
        .start_offset = 2,
        .end_offset = 2,
        .instructions = &.{},
        .successors = succ_1[0..],
        .predecessors = preds_1[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    blocks[2] = .{
        .id = 2,
        .start_offset = 4,
        .end_offset = 4,
        .instructions = &.{},
        .successors = succ_2[0..],
        .predecessors = preds_2[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };

    var cfg = cfg_mod.CFG{
        .allocator = allocator,
        .blocks = blocks[0..],
        .block_offsets = @constCast(block_offsets),
        .entry = 0,
        .instructions = &.{},
        .exception_entries = &.{},
        .version = version,
    };

    var dom = try dom_mod.DomTree.init(allocator, &cfg);
    defer dom.deinit();

    var analyzer = try Analyzer.init(allocator, &cfg, &dom);
    defer analyzer.deinit();

    try testing.expect(analyzer.detectWhilePattern(0, false) == null);
}

test "detectPattern async for header prefers try" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const version = cfg_mod.Version.init(3, 7);
    const total_blocks: usize = 3;

    const instructions = try allocator.alloc(cfg_mod.Instruction, 6);
    const block_offsets = try allocator.alloc(u32, total_blocks);
    const blocks = try allocator.alloc(cfg_mod.BasicBlock, total_blocks);

    instructions[0] = .{ .opcode = .SETUP_EXCEPT, .arg = 0, .offset = 0, .size = 2, .cache_entries = 0 };
    instructions[1] = .{ .opcode = .GET_ANEXT, .arg = 0, .offset = 2, .size = 2, .cache_entries = 0 };
    instructions[2] = .{ .opcode = .LOAD_CONST, .arg = 0, .offset = 4, .size = 2, .cache_entries = 0 };
    instructions[3] = .{ .opcode = .YIELD_FROM, .arg = 0, .offset = 6, .size = 2, .cache_entries = 0 };
    instructions[4] = .{ .opcode = .POP_BLOCK, .arg = 0, .offset = 8, .size = 2, .cache_entries = 0 };
    instructions[5] = .{ .opcode = .NOP, .arg = 0, .offset = 10, .size = 2, .cache_entries = 0 };

    block_offsets[0] = 0;
    block_offsets[1] = 10;
    block_offsets[2] = 12;

    var succ_0 = try allocator.alloc(cfg_mod.Edge, 2);
    succ_0[0] = .{ .target = 2, .edge_type = .normal };
    succ_0[1] = .{ .target = 1, .edge_type = .exception };

    var succ_1 = try allocator.alloc(cfg_mod.Edge, 1);
    succ_1[0] = .{ .target = 2, .edge_type = .normal };

    var succ_2 = try allocator.alloc(cfg_mod.Edge, 1);
    succ_2[0] = .{ .target = 0, .edge_type = .loop_back };

    var preds_0 = try allocator.alloc(u32, 1);
    preds_0[0] = 2;
    var preds_1 = try allocator.alloc(u32, 1);
    preds_1[0] = 0;
    var preds_2 = try allocator.alloc(u32, 2);
    preds_2[0] = 0;
    preds_2[1] = 1;

    blocks[0] = .{
        .id = 0,
        .start_offset = 0,
        .end_offset = 10,
        .instructions = instructions[0..5],
        .successors = succ_0,
        .predecessors = preds_0,
        .is_exception_handler = false,
        .is_loop_header = true,
    };
    blocks[1] = .{
        .id = 1,
        .start_offset = 10,
        .end_offset = 12,
        .instructions = instructions[5..6],
        .successors = succ_1,
        .predecessors = preds_1,
        .is_exception_handler = true,
        .is_loop_header = false,
    };
    blocks[2] = .{
        .id = 2,
        .start_offset = 12,
        .end_offset = 12,
        .instructions = instructions[6..6],
        .successors = succ_2,
        .predecessors = preds_2,
        .is_exception_handler = false,
        .is_loop_header = false,
    };

    var cfg = cfg_mod.CFG{
        .allocator = allocator,
        .blocks = blocks,
        .block_offsets = block_offsets,
        .entry = 0,
        .instructions = instructions,
        .exception_entries = &.{},
        .version = version,
    };
    defer cfg.deinit();

    var dom = try dom_mod.DomTree.init(allocator, &cfg);
    defer dom.deinit();

    var analyzer = try Analyzer.init(allocator, &cfg, &dom);
    defer analyzer.deinit();

    const pat = try analyzer.detectPattern(0);
    switch (pat) {
        .try_stmt => {},
        else => try testing.expect(false),
    }
}

test "isConditionalJump" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const blocks: []BasicBlock = &.{};
    const block_offsets = &[_]u32{};
    var cfg_val = CFG{
        .allocator = allocator,
        .blocks = blocks,
        .block_offsets = @constCast(block_offsets),
        .entry = 0,
        .instructions = &.{},
        .exception_entries = &.{},
        .version = Version.init(3, 12),
    };

    var dom = try dom_mod.DomTree.init(allocator, &cfg_val);
    defer dom.deinit();
    var analyzer = try Analyzer.init(allocator, &cfg_val, &dom);
    defer analyzer.deinit();

    try testing.expect(analyzer.isConditionalJump(.POP_JUMP_IF_TRUE));
    try testing.expect(analyzer.isConditionalJump(.POP_JUMP_IF_FALSE));
    try testing.expect(analyzer.isConditionalJump(.POP_JUMP_IF_NONE));
    try testing.expect(analyzer.isConditionalJump(.JUMP_IF_NOT_EXC_MATCH));
    try testing.expect(!analyzer.isConditionalJump(.JUMP_FORWARD));
    try testing.expect(!analyzer.isConditionalJump(.LOAD_CONST));
}

test "detectForPattern walks deep predecessor chain" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const version = Version.init(3, 11);
    const chain_len: u32 = 18;
    const setup_block: u32 = 0;
    const header_block: u32 = chain_len;
    const body_block: u32 = header_block + 1;
    const exit_block: u32 = header_block + 2;
    const total_blocks: usize = @intCast(exit_block + 1);

    const instructions = try allocator.alloc(Instruction, total_blocks);
    const block_offsets = try allocator.alloc(u32, total_blocks);
    const blocks = try allocator.alloc(BasicBlock, total_blocks);

    var i: usize = 0;
    while (i < total_blocks) : (i += 1) {
        const off: u32 = @intCast(i * 2);
        instructions[i] = .{
            .opcode = .NOP,
            .arg = 0,
            .offset = off,
            .size = 2,
            .cache_entries = 0,
        };
        block_offsets[i] = off;
    }
    instructions[setup_block].opcode = .GET_ITER;
    instructions[header_block].opcode = .FOR_ITER;

    i = 0;
    while (i < total_blocks) : (i += 1) {
        var succs: []Edge = &.{};
        var preds: []u32 = &.{};

        if (i < header_block) {
            succs = try allocator.alloc(Edge, 1);
            succs[0] = .{ .target = @intCast(i + 1), .edge_type = .normal };
        } else if (i == header_block) {
            succs = try allocator.alloc(Edge, 2);
            succs[0] = .{ .target = body_block, .edge_type = .normal };
            succs[1] = .{ .target = exit_block, .edge_type = .conditional_false };
        }

        if (i == 0) {
            preds = &.{};
        } else if (i <= header_block) {
            preds = try allocator.alloc(u32, 1);
            preds[0] = @intCast(i - 1);
        } else if (i == body_block or i == exit_block) {
            preds = try allocator.alloc(u32, 1);
            preds[0] = header_block;
        }

        blocks[i] = .{
            .id = @intCast(i),
            .start_offset = block_offsets[i],
            .end_offset = block_offsets[i] + 2,
            .instructions = instructions[i .. i + 1],
            .successors = succs,
            .predecessors = preds,
            .is_exception_handler = false,
            .is_loop_header = i == header_block,
        };
    }

    var cfg = CFG{
        .allocator = allocator,
        .blocks = blocks,
        .block_offsets = block_offsets,
        .entry = 0,
        .instructions = instructions,
        .exception_entries = &.{},
        .version = version,
    };
    defer cfg.deinit();

    var dom = try dom_mod.DomTree.init(allocator, &cfg);
    defer dom.deinit();
    var analyzer = try Analyzer.init(allocator, &cfg, &dom);
    defer analyzer.deinit();

    const pattern_opt = analyzer.detectForPattern(header_block);
    try testing.expect(pattern_opt != null);
    const pattern = pattern_opt.?;
    try testing.expectEqual(setup_block, pattern.setup_block);
}
