//! Control Flow Graph (CFG) construction and analysis.
//!
//! Builds a CFG from Python bytecode for use in decompilation.
//! The CFG represents the program as basic blocks connected by edges.

const std = @import("std");
const Allocator = std.mem.Allocator;
const decoder = @import("decoder.zig");
const opcodes = @import("opcodes.zig");

pub const Instruction = decoder.Instruction;
pub const Version = decoder.Version;
pub const Opcode = decoder.Opcode;

/// Edge type in the control flow graph.
pub const EdgeType = enum {
    /// Normal control flow (fallthrough or unconditional jump).
    normal,
    /// Conditional branch taken (e.g., POP_JUMP_IF_TRUE when true).
    conditional_true,
    /// Conditional branch not taken (fallthrough when false).
    conditional_false,
    /// Exception handler entry.
    exception,
    /// Loop back edge (for detecting loops).
    loop_back,
};

/// An edge in the control flow graph.
pub const Edge = struct {
    /// Index of the target basic block.
    target: u32,
    /// Type of this edge.
    edge_type: EdgeType,
};

/// A basic block in the control flow graph.
pub const BasicBlock = struct {
    /// Unique identifier for this block.
    id: u32,
    /// Byte offset of the first instruction in this block.
    start_offset: u32,
    /// Byte offset just past the last instruction in this block.
    end_offset: u32,
    /// Instructions in this block.
    instructions: []const Instruction,
    /// Outgoing edges to successor blocks.
    successors: []Edge,
    /// Incoming edges from predecessor blocks.
    predecessors: []u32,
    /// True if this block is an exception handler entry.
    is_exception_handler: bool,
    /// True if this block is a loop header.
    is_loop_header: bool,

    /// Get the terminating instruction of this block.
    pub fn terminator(self: BasicBlock) ?Instruction {
        if (self.instructions.len == 0) return null;
        return self.instructions[self.instructions.len - 1];
    }

    /// Check if this block falls through to the next block.
    pub fn fallsThrough(self: BasicBlock) bool {
        const term = self.terminator() orelse return true;
        return !term.isBlockTerminator();
    }
};

/// Control flow graph for a code object.
pub const CFG = struct {
    allocator: Allocator,
    /// All basic blocks, indexed by their id.
    blocks: []BasicBlock,
    /// Entry block id (always 0).
    entry: u32,
    /// All instructions in order.
    instructions: []Instruction,
    /// Python version for jump target calculation.
    version: Version,

    pub fn deinit(self: *CFG) void {
        for (self.blocks) |*block| {
            if (block.successors.len > 0) self.allocator.free(block.successors);
            if (block.predecessors.len > 0) self.allocator.free(block.predecessors);
        }
        if (self.blocks.len > 0) self.allocator.free(self.blocks);
        if (self.instructions.len > 0) self.allocator.free(self.instructions);
    }

    /// Get block by id.
    pub fn getBlock(self: *const CFG, id: u32) ?*const BasicBlock {
        if (id >= self.blocks.len) return null;
        return &self.blocks[id];
    }

    /// Find the block containing a given byte offset.
    pub fn blockContaining(self: *const CFG, offset: u32) ?*const BasicBlock {
        for (self.blocks) |*block| {
            if (offset >= block.start_offset and offset < block.end_offset) {
                return block;
            }
        }
        return null;
    }

    /// Find block by start offset (for jump targets).
    pub fn blockAtOffset(self: *const CFG, offset: u32) ?u32 {
        for (self.blocks, 0..) |block, i| {
            if (block.start_offset == offset) {
                return @intCast(i);
            }
        }
        return null;
    }
};

/// Build a CFG from bytecode.
pub fn buildCFG(allocator: Allocator, bytecode: []const u8, version: Version) !CFG {
    // Step 1: Decode all instructions
    var iter = decoder.InstructionIterator.init(bytecode, version);
    const instructions = try iter.collectAlloc(allocator);
    errdefer allocator.free(instructions);

    if (instructions.len == 0) {
        return CFG{
            .allocator = allocator,
            .blocks = &.{},
            .entry = 0,
            .instructions = instructions,
            .version = version,
        };
    }

    // Step 2: Find block leaders (start of basic blocks)
    // Leaders are:
    // - First instruction
    // - Target of any jump
    // - Instruction following a jump or terminator
    var leaders = std.AutoHashMap(u32, void).init(allocator);
    defer leaders.deinit();

    // First instruction is always a leader
    try leaders.put(instructions[0].offset, {});

    for (instructions, 0..) |inst, i| {
        // If this is a jump, the target is a leader
        if (inst.jumpTarget(version)) |target| {
            try leaders.put(target, {});
        }

        // If this is a branch or terminator, next instruction (if any) is a leader
        if (inst.isJump() or inst.isBlockTerminator()) {
            if (i + 1 < instructions.len) {
                try leaders.put(instructions[i + 1].offset, {});
            }
        }
    }

    // Step 3: Create basic blocks from leaders
    // Sort leader offsets
    var leader_offsets: std.ArrayList(u32) = .{};
    defer leader_offsets.deinit(allocator);

    var leader_iter = leaders.keyIterator();
    while (leader_iter.next()) |offset| {
        try leader_offsets.append(allocator, offset.*);
    }

    std.mem.sort(u32, leader_offsets.items, {}, std.sort.asc(u32));

    // Map from offset to block id
    var offset_to_block = std.AutoHashMap(u32, u32).init(allocator);
    defer offset_to_block.deinit();

    for (leader_offsets.items, 0..) |offset, i| {
        try offset_to_block.put(offset, @intCast(i));
    }

    // Create blocks
    var blocks = try allocator.alloc(BasicBlock, leader_offsets.items.len);
    errdefer allocator.free(blocks);

    var inst_idx: usize = 0;
    for (leader_offsets.items, 0..) |leader_offset, block_idx| {
        const block_id: u32 = @intCast(block_idx);

        // Find the end offset (start of next block or end of bytecode)
        const end_offset: u32 = if (block_idx + 1 < leader_offsets.items.len)
            leader_offsets.items[block_idx + 1]
        else
            @intCast(bytecode.len);

        // Find instructions belonging to this block
        const start_inst_idx = inst_idx;
        while (inst_idx < instructions.len and instructions[inst_idx].offset < end_offset) {
            inst_idx += 1;
        }

        blocks[block_idx] = BasicBlock{
            .id = block_id,
            .start_offset = leader_offset,
            .end_offset = end_offset,
            .instructions = instructions[start_inst_idx..inst_idx],
            .successors = &.{},
            .predecessors = &.{},
            .is_exception_handler = false,
            .is_loop_header = false,
        };
    }

    // Step 4: Build edges
    for (blocks, 0..) |*block, block_idx| {
        var succ_list: std.ArrayList(Edge) = .{};
        errdefer succ_list.deinit(allocator);

        const term = block.terminator();

        // Check for jump edge
        if (term) |t| {
            if (t.jumpTarget(version)) |target| {
                if (offset_to_block.get(target)) |target_block| {
                    const edge_type: EdgeType = if (t.isConditionalJump())
                        .conditional_true
                    else if (t.opcode == .JUMP_BACKWARD or t.opcode == .JUMP_BACKWARD_NO_INTERRUPT)
                        .loop_back
                    else
                        .normal;
                    try succ_list.append(allocator, .{ .target = target_block, .edge_type = edge_type });
                }
            }
        }

        // Check for fallthrough edge
        if (block.fallsThrough()) {
            if (block_idx + 1 < blocks.len) {
                const edge_type: EdgeType = if (term != null and term.?.isConditionalJump())
                    .conditional_false
                else
                    .normal;
                try succ_list.append(allocator, .{ .target = @intCast(block_idx + 1), .edge_type = edge_type });
            }
        }

        block.successors = try succ_list.toOwnedSlice(allocator);
    }

    // Step 5: Build predecessor lists
    for (blocks) |*block| {
        var pred_count: usize = 0;
        for (blocks) |other| {
            for (other.successors) |edge| {
                if (edge.target == block.id) {
                    pred_count += 1;
                }
            }
        }

        if (pred_count > 0) {
            const preds = try allocator.alloc(u32, pred_count);
            var idx: usize = 0;
            for (blocks) |other| {
                for (other.successors) |edge| {
                    if (edge.target == block.id) {
                        preds[idx] = other.id;
                        idx += 1;
                    }
                }
            }
            block.predecessors = preds;
        }
    }

    // Step 6: Detect loop headers (blocks with back edges)
    for (blocks) |*block| {
        for (block.predecessors) |pred_id| {
            if (pred_id >= block.id) {
                // Predecessor has higher/equal id, indicating a back edge
                for (blocks[pred_id].successors) |edge| {
                    if (edge.target == block.id and edge.edge_type == .loop_back) {
                        block.is_loop_header = true;
                        break;
                    }
                }
            }
        }
    }

    return CFG{
        .allocator = allocator,
        .blocks = blocks,
        .entry = 0,
        .instructions = instructions,
        .version = version,
    };
}

/// Print CFG in a debug format.
pub fn debugPrint(cfg: *const CFG, writer: anytype) !void {
    try writer.print("CFG with {d} blocks:\n", .{cfg.blocks.len});

    for (cfg.blocks) |block| {
        try writer.print("\nBlock {d} [{d}-{d})", .{ block.id, block.start_offset, block.end_offset });
        if (block.is_loop_header) try writer.writeAll(" [LOOP HEADER]");
        if (block.is_exception_handler) try writer.writeAll(" [EXCEPTION]");
        try writer.writeByte('\n');

        // Print instructions
        for (block.instructions) |inst| {
            try writer.print("  {d:4}: {s}", .{ inst.offset, inst.opcode.name() });
            if (inst.opcode.hasArg(cfg.version)) {
                try writer.print(" {d}", .{inst.arg});
            }
            try writer.writeByte('\n');
        }

        // Print edges
        if (block.successors.len > 0) {
            try writer.writeAll("  -> ");
            for (block.successors, 0..) |edge, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{d}", .{edge.target});
                switch (edge.edge_type) {
                    .conditional_true => try writer.writeAll(" (true)"),
                    .conditional_false => try writer.writeAll(" (false)"),
                    .loop_back => try writer.writeAll(" (back)"),
                    .exception => try writer.writeAll(" (exc)"),
                    .normal => {},
                }
            }
            try writer.writeByte('\n');
        }
    }
}

test "cfg simple function" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const v312 = Version.init(3, 12);

    // Simple function: RESUME, LOAD_FAST, LOAD_FAST, BINARY_OP, RETURN_VALUE
    // No jumps, so should be a single basic block
    const bytecode = [_]u8{
        151, 0, // RESUME 0
        124, 0, // LOAD_FAST 0
        124, 1, // LOAD_FAST 1
        122, 0, // BINARY_OP 0
        0, 0, // cache
        83, 0, // RETURN_VALUE
    };

    var cfg = try buildCFG(allocator, &bytecode, v312);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.blocks.len);
    try testing.expectEqual(@as(u32, 0), cfg.blocks[0].start_offset);
    try testing.expectEqual(@as(u32, 12), cfg.blocks[0].end_offset);
    try testing.expectEqual(@as(usize, 5), cfg.blocks[0].instructions.len);
}

test "cfg with conditional" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const v312 = Version.init(3, 12);

    // if x: return 1 else: return 2
    // RESUME, LOAD_FAST, POP_JUMP_IF_FALSE (to else), RETURN_CONST 1, RETURN_CONST 2
    // POP_JUMP_IF_FALSE is byte 114, target is instruction offset in 3.12
    // Note: POP_JUMP_IF_FALSE has NO cache entries in 3.12
    const bytecode = [_]u8{
        151, 0, // RESUME 0 @ 0
        124, 0, // LOAD_FAST 0 @ 2
        114, 4, // POP_JUMP_IF_FALSE to offset 8 (4 * 2) @ 4
        121, 0, // RETURN_CONST 0 (then branch) @ 6
        121, 1, // RETURN_CONST 1 (else branch) @ 8
    };

    var cfg = try buildCFG(allocator, &bytecode, v312);
    defer cfg.deinit();

    // Should have 3 blocks:
    // Block 0: RESUME, LOAD_FAST, POP_JUMP_IF_FALSE (start=0, end=6)
    // Block 1: RETURN_CONST 0 (then) (start=6, end=8)
    // Block 2: RETURN_CONST 1 (else) (start=8, end=10)
    try testing.expectEqual(@as(usize, 3), cfg.blocks.len);

    // Block 0 should have two successors (true -> block 2, false -> block 1)
    try testing.expectEqual(@as(usize, 2), cfg.blocks[0].successors.len);
}
