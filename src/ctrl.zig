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

pub const CFG = cfg_mod.CFG;
pub const BasicBlock = cfg_mod.BasicBlock;
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
    /// Block after the loop.
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

/// Control flow analyzer.
pub const Analyzer = struct {
    cfg: *const CFG,
    allocator: Allocator,
    /// Blocks that have been processed/claimed by a pattern.
    processed: std.DynamicBitSet,

    pub fn init(allocator: Allocator, cfg_ptr: *const CFG) !Analyzer {
        const processed = try std.DynamicBitSet.initEmpty(allocator, cfg_ptr.blocks.len);
        return .{
            .cfg = cfg_ptr,
            .allocator = allocator,
            .processed = processed,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.processed.deinit();
    }

    /// Detect the control flow pattern starting at a block.
    pub fn detectPattern(self: *Analyzer, block_id: u32) !ControlFlowPattern {
        if (block_id >= self.cfg.blocks.len) return .unknown;
        if (self.processed.isSet(block_id)) return .unknown;

        const block = &self.cfg.blocks[block_id];
        const term = block.terminator() orelse return .unknown;

        // Check for exception handler with CHECK_EXC_MATCH - not a regular if
        if (block.is_exception_handler or self.hasCheckExcMatch(block)) {
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
            if (self.detectWhilePattern(block_id)) |pattern| {
                return .{ .while_loop = pattern };
            }
        }

        // Check for conditional jump (if statement pattern)
        if (self.isConditionalJump(term.opcode)) {
            if (try self.detectIfPattern(block_id)) |pattern| {
                return .{ .if_stmt = pattern };
            }
        }

        // Check for FOR_ITER (for loop pattern)
        if (term.opcode == .FOR_ITER) {
            if (self.detectForPattern(block_id)) |pattern| {
                return .{ .for_loop = pattern };
            }
        }

        // Check for with statement (BEFORE_WITH opcode)
        if (self.hasWithSetup(block)) {
            if (self.detectWithPattern(block_id)) |pattern| {
                return .{ .with_stmt = pattern };
            }
        }

        // Check for try/except pattern (block with exception edge)
        if (self.hasExceptionEdge(block)) {
            if (try self.detectTryPattern(block_id)) |pattern| {
                return .{ .try_stmt = pattern };
            }
        }

        return .unknown;
    }

    /// Check if block has any exception edges.
    fn hasExceptionEdge(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        for (block.successors) |edge| {
            if (edge.edge_type == .exception) return true;
        }
        return false;
    }

    /// Check if block has BEFORE_WITH setup.
    fn hasWithSetup(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        for (block.instructions) |inst| {
            if (inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH or inst.opcode == .LOAD_SPECIAL) return true;
        }
        return false;
    }

    /// Check if block has CHECK_EXC_MATCH (exception handler).
    fn hasCheckExcMatch(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        var has_dup = false;
        var has_exc_cmp = false;
        var has_jump = false;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .CHECK_EXC_MATCH, .PUSH_EXC_INFO => return true,
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
        if (block.successors.len != 2) return null;

        // Check for COPY, TO_BOOL, POP_JUMP pattern at end of block
        const insts = block.instructions;
        if (insts.len < 2) return null;

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

        for (block.successors) |edge| {
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
            for (block.successors) |edge| {
                switch (edge.edge_type) {
                    .conditional_true, .normal => second_block = edge.target,
                    .conditional_false => short_circuit_block = edge.target,
                    else => {},
                }
            }
        } else {
            // POP_JUMP_IF_TRUE: fallthrough is second_block, jump is short_circuit
            for (block.successors) |edge| {
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
    pub fn isConditionalJump(self: *const Analyzer, opcode: Opcode) bool {
        _ = self;
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
            => true,
            else => false,
        };
    }

    /// Detect if/elif/else pattern.
    fn detectIfPattern(self: *Analyzer, block_id: u32) !?IfPattern {
        const block = &self.cfg.blocks[block_id];

        // Need exactly two successors for a conditional
        if (block.successors.len != 2) return null;

        var then_block: ?u32 = null;
        var else_block: ?u32 = null;

        // Identify then and else blocks based on edge types
        for (block.successors) |edge| {
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
            for (block.successors) |edge| {
                if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                    then_block = edge.target;
                } else if (edge.edge_type == .conditional_false) {
                    else_block = edge.target;
                }
            }
        }

        const then_id = then_block orelse return null;

        // Find merge point - where both branches converge
        const merge = try self.findMergePoint(then_id, else_block);

        // Check if else block is actually an elif
        var is_elif = false;
        if (else_block) |else_id| {
            const else_blk = &self.cfg.blocks[else_id];
            if (else_blk.terminator()) |else_term| {
                if (self.isConditionalJump(else_term.opcode)) {
                    is_elif = true;
                }
            }
        }

        return IfPattern{
            .condition_block = block_id,
            .then_block = then_id,
            .else_block = else_block,
            .merge_block = merge,
            .is_elif = is_elif,
        };
    }

    /// Detect while loop pattern.
    fn detectWhilePattern(self: *Analyzer, block_id: u32) ?WhilePattern {
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

        const body_id = body_block orelse return null;
        const exit_id = exit_block orelse return null;

        return WhilePattern{
            .header_block = block_id,
            .body_block = body_id,
            .exit_block = exit_id,
        };
    }

    /// Detect for loop pattern.
    fn detectForPattern(self: *Analyzer, block_id: u32) ?ForPattern {
        const block = &self.cfg.blocks[block_id];
        const term = block.terminator() orelse return null;

        if (term.opcode != .FOR_ITER) return null;

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

        // Look backwards for GET_ITER in predecessor
        var setup_block: u32 = block_id;
        if (block.predecessors.len > 0) {
            for (block.predecessors) |pred_id| {
                const pred = &self.cfg.blocks[pred_id];
                // Check if predecessor has GET_ITER
                for (pred.instructions) |inst| {
                    if (inst.opcode == .GET_ITER) {
                        setup_block = pred_id;
                        break;
                    }
                }
            }
        }

        const body_id = body_block orelse return null;
        const exit_id = exit_block orelse return null;

        return ForPattern{
            .setup_block = setup_block,
            .header_block = block_id,
            .body_block = body_id,
            .exit_block = exit_id,
        };
    }

    /// Detect try/except/finally pattern.
    fn detectTryPattern(self: *Analyzer, block_id: u32) !?TryPattern {
        if (block_id >= self.cfg.blocks.len) return null;
        const block = &self.cfg.blocks[block_id];
        if (block.is_exception_handler) return null;

        if (!self.cfg.version.gte(3, 11)) {
            var has_setup = false;
            for (block.instructions) |inst| {
                if (inst.opcode == .SETUP_EXCEPT or inst.opcode == .SETUP_FINALLY) {
                    has_setup = true;
                    break;
                }
            }
            if (!has_setup) return null;
        }

        var handler_targets: std.ArrayList(u32) = .{};
        defer handler_targets.deinit(self.allocator);

        try self.collectExceptionTargets(block_id, &handler_targets);
        if (handler_targets.items.len == 0) return null;

        // Collect all exception handlers reachable from this block
        var handler_list: std.ArrayList(HandlerInfo) = .{};
        defer handler_list.deinit(self.allocator);

        for (handler_targets.items) |hid| {
            if (hid >= self.cfg.blocks.len) continue;
            const handler_block = &self.cfg.blocks[hid];
            // Skip generator StopIteration handlers (CALL_INTRINSIC_1 + RERAISE)
            if (self.isStopIterHandler(handler_block)) continue;
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

        return TryPattern{
            .try_block = block_id,
            .handlers = handlers,
            .else_block = null, // TODO: detect else clause
            .finally_block = null, // TODO: detect finally clause
            .exit_block = exit_block,
        };
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
        targets: *std.ArrayList(u32),
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

    /// Check if handler block has exception type check (CHECK_EXC_MATCH).
    fn hasExceptionTypeCheck(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        for (block.instructions) |inst| {
            if (inst.opcode == .CHECK_EXC_MATCH) return true;
            if (inst.opcode == .COMPARE_OP and inst.arg == 10) return true;
        }
        return false;
    }

    /// Detect with statement pattern.
    fn detectWithPattern(self: *Analyzer, block_id: u32) ?WithPattern {
        const block = &self.cfg.blocks[block_id];

        // Find BEFORE_WITH/BEFORE_ASYNC_WITH/LOAD_SPECIAL instruction
        var has_before_with = false;
        for (block.instructions) |inst| {
            if (inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH or inst.opcode == .LOAD_SPECIAL) {
                has_before_with = true;
                break;
            }
        }

        if (!has_before_with) return null;

        // The body is the normal successor
        var body_block: ?u32 = null;
        var cleanup_block: ?u32 = null;

        // In Python 3.14+, exception protection starts at body, not setup
        // Setup block has LOAD_SPECIAL but no exception edge
        // Body block has the exception edge to cleanup
        for (block.successors) |edge| {
            if (edge.edge_type == .normal) {
                body_block = edge.target;
            } else if (edge.edge_type == .exception) {
                cleanup_block = edge.target;
            }
        }

        const body_id = body_block orelse return null;

        // If no exception edge from setup, check the body block for exception edge
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
        // Check if current block has MATCH_* opcode
        if (self.hasMatchOpcode(block)) return true;

        // Check if successor block starts with MATCH_* or COPY+MATCH
        if (block.successors.len == 0) return false;
        const succ_id = block.successors[0].target;
        if (succ_id >= self.cfg.blocks.len) return false;
        const succ = &self.cfg.blocks[succ_id];

        return self.hasMatchOpcode(succ) or self.hasMatchPattern(succ);
    }

    /// Check if block has a MATCH_* opcode.
    fn hasMatchOpcode(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        for (block.instructions) |inst| {
            if (inst.opcode == .MATCH_SEQUENCE or
                inst.opcode == .MATCH_MAPPING or
                inst.opcode == .MATCH_CLASS)
            {
                return true;
            }
        }
        return false;
    }

    /// Check if block has a match pattern (COPY followed by MATCH_* or literal compare).
    fn hasMatchPattern(self: *const Analyzer, block: *const BasicBlock) bool {
        _ = self;
        var has_copy = false;
        var has_match_op = false;

        for (block.instructions) |inst| {
            if (inst.opcode == .COPY) has_copy = true;
            if (inst.opcode == .MATCH_SEQUENCE or
                inst.opcode == .MATCH_MAPPING or
                inst.opcode == .MATCH_CLASS)
            {
                has_match_op = true;
            }
            // COPY + COMPARE_OP is literal case match
            if (has_copy and inst.opcode == .COMPARE_OP) {
                has_match_op = true;
            }
        }
        return has_copy and has_match_op;
    }

    /// Detect match statement pattern.
    fn detectMatchPattern(self: *Analyzer, block_id: u32) !?MatchPattern {
        const block = &self.cfg.blocks[block_id];

        var case_blocks: std.ArrayList(u32) = .{};
        defer case_blocks.deinit(self.allocator);

        // If current block has MATCH_*, it's both subject and first case
        var current: u32 = if (self.hasMatchOpcode(block))
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
            if (!self.hasMatchOpcode(cur_block) and !self.hasMatchPattern(cur_block) and !self.isWildcardCase(cur_block)) {
                // Not a case block - this might be exit
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
                // Check if it's followed by body (no conditional jump)
                if (block.successors.len == 1) return true;
            }
        }
        return false;
    }

    /// Find the merge point where two branches converge.
    fn findMergePoint(self: *Analyzer, then_block: u32, else_block: ?u32) !?u32 {
        const else_id = else_block orelse return null;

        // Simple approach: follow each branch until we find a common successor
        var then_visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer then_visited.deinit();

        // Mark all blocks reachable from then-branch
        var queue: std.ArrayList(u32) = .{};
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, then_block);

        while (queue.items.len > 0) {
            const bid = queue.pop().?;
            if (then_visited.contains(bid)) continue;
            try then_visited.put(bid, {});

            const blk = &self.cfg.blocks[bid];
            for (blk.successors) |edge| {
                if (!then_visited.contains(edge.target)) {
                    try queue.append(self.allocator, edge.target);
                }
            }
        }

        // Find first block reachable from else-branch that's also in then-visited
        queue.clearRetainingCapacity();
        var else_visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer else_visited.deinit();
        try queue.append(self.allocator, else_id);

        while (queue.items.len > 0) {
            const bid = queue.pop().?;
            if (else_visited.contains(bid)) continue;

            // Check if this block is reachable from then-branch
            if (then_visited.contains(bid)) {
                return bid;
            }

            try else_visited.put(bid, {});

            const blk = &self.cfg.blocks[bid];
            for (blk.successors) |edge| {
                if (!else_visited.contains(edge.target)) {
                    try queue.append(self.allocator, edge.target);
                }
            }
        }

        return null;
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
    pub fn detectLoopExit(self: *const Analyzer, block_id: u32, loop_headers: []const u32) LoopExit {
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

            // Check if jumping past the innermost loop's exit = break
            // For simplicity, if we jump forward and out of the loop body, it's a break
            if (loop_headers.len > 0) {
                const innermost_header = loop_headers[loop_headers.len - 1];
                const header_block = &self.cfg.blocks[innermost_header];

                // Find the loop's exit block
                for (header_block.successors) |edge| {
                    if (edge.edge_type == .conditional_false) {
                        // This is the exit block - if we're jumping to it or past, it's a break
                        if (target_block >= edge.target) {
                            return .{ .break_stmt = .{
                                .block = block_id,
                                .loop_header = innermost_header,
                            } };
                        }
                    }
                }
            }
        }

        return .none;
    }

    /// Find all loop headers that contain a given block.
    pub fn findEnclosingLoops(self: *const Analyzer, block_id: u32) ![]u32 {
        var loops: std.ArrayList(u32) = .{};
        errdefer loops.deinit(self.allocator);

        // Simple approach: a block is in a loop if there's a path from a loop header
        // to the block and a back edge from somewhere after the block to the header
        for (self.cfg.blocks, 0..) |block, i| {
            if (block.is_loop_header) {
                // Check if block_id is reachable from this loop header
                // and if there's a back edge to this header from a block >= block_id
                const header_id: u32 = @intCast(i);
                if (self.isInLoop(block_id, header_id)) {
                    try loops.append(self.allocator, header_id);
                }
            }
        }

        return loops.toOwnedSlice(self.allocator);
    }

    /// Check if a block is within a loop.
    fn isInLoop(self: *const Analyzer, block_id: u32, loop_header: u32) bool {
        // A block is in a loop if:
        // 1. It's reachable from the loop header via normal/true edges
        // 2. There's a back edge to the loop header from some block after it

        if (block_id == loop_header) return true;
        if (block_id < loop_header) return false;

        // Check if this block can reach the loop header via a back edge
        const block = &self.cfg.blocks[block_id];
        for (block.successors) |edge| {
            if (edge.edge_type == .loop_back and edge.target == loop_header) {
                return true;
            }
        }

        // Check if any successor is in the loop (without going through back edges)
        // This is approximate - for precise analysis we'd need dominance info
        const header = &self.cfg.blocks[loop_header];
        for (header.successors) |edge| {
            if (edge.edge_type == .conditional_true or edge.edge_type == .normal) {
                // The loop body starts here
                const body_start = edge.target;
                if (block_id >= body_start and block_id < loop_header + 10) {
                    // Approximate: block is between body start and some blocks after
                    return true;
                }
            }
        }

        return false;
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

    var cfg_val = CFG{
        .allocator = allocator,
        .blocks = blocks,
        .entry = 0,
        .instructions = &.{},
        .version = Version.init(3, 12),
    };

    var analyzer = try Analyzer.init(allocator, &cfg_val);
    defer analyzer.deinit();

    try testing.expectEqual(@as(usize, 2), cfg_val.blocks.len);
}

test "isConditionalJump" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const blocks: []BasicBlock = &.{};
    var cfg_val = CFG{
        .allocator = allocator,
        .blocks = blocks,
        .entry = 0,
        .instructions = &.{},
        .version = Version.init(3, 12),
    };

    var analyzer = try Analyzer.init(allocator, &cfg_val);
    defer analyzer.deinit();

    try testing.expect(analyzer.isConditionalJump(.POP_JUMP_IF_TRUE));
    try testing.expect(analyzer.isConditionalJump(.POP_JUMP_IF_FALSE));
    try testing.expect(analyzer.isConditionalJump(.POP_JUMP_IF_NONE));
    try testing.expect(!analyzer.isConditionalJump(.JUMP_FORWARD));
    try testing.expect(!analyzer.isConditionalJump(.LOAD_CONST));
}
