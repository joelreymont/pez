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
    pub fn terminator(self: *const BasicBlock) ?Instruction {
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
    /// Sorted block start offsets (same order as blocks).
    block_offsets: []u32,
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
        if (self.block_offsets.len > 0) self.allocator.free(self.block_offsets);
        if (self.instructions.len > 0) self.allocator.free(self.instructions);
    }

    /// Get block by id.
    pub fn getBlock(self: *const CFG, id: u32) ?*const BasicBlock {
        if (id >= self.blocks.len) return null;
        return &self.blocks[id];
    }

    /// Write CFG as DOT graph.
    pub fn writeDot(self: *const CFG, writer: anytype) !void {
        try writer.writeAll("digraph CFG {\n");
        try writer.writeAll("  node [shape=box];\n");

        for (self.blocks) |block| {
            try writer.print("  block{} [label=\"Block {}", .{ block.id, block.id });
            if (block.is_exception_handler) try writer.writeAll(" (handler)");
            if (block.is_loop_header) try writer.writeAll(" (loop)");
            try writer.print("\\noffset {}\"", .{block.start_offset});
            if (block.is_exception_handler) try writer.writeAll(", color=red");
            if (block.is_loop_header) try writer.writeAll(", color=blue");
            try writer.writeAll("];\n");

            for (block.successors) |edge| {
                const style = switch (edge.edge_type) {
                    .normal => "",
                    .conditional_true => ", label=\"true\", color=green",
                    .conditional_false => ", label=\"false\", color=red",
                    .exception => ", label=\"exception\", style=dashed, color=red",
                    .loop_back => ", label=\"loop\", color=blue, constraint=false",
                };
                try writer.print("  block{} -> block{}{};\n", .{ block.id, edge.target, style });
            }
        }

        try writer.writeAll("}\n");
    }

    /// Find the block containing a given byte offset.
    pub fn blockContaining(self: *const CFG, offset: u32) ?*const BasicBlock {
        if (self.block_offsets.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = self.block_offsets.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.block_offsets[mid] <= offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        const idx = lo - 1;
        const block = &self.blocks[idx];
        if (offset >= block.start_offset and offset < block.end_offset) {
            return block;
        }
        return null;
    }

    /// Find block by start offset (for jump targets).
    pub fn blockAtOffset(self: *const CFG, offset: u32) ?u32 {
        if (self.block_offsets.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = self.block_offsets.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const mid_off = self.block_offsets[mid];
            if (mid_off == offset) return @intCast(mid);
            if (mid_off < offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }
};

/// Post-dominator tree and sets for a CFG.
pub const PostDom = struct {
    allocator: Allocator,
    sets: []std.DynamicBitSet,
    ipdom: []?u32,
    depth: []u32,
    virtual_exit: ?u32,

    pub fn deinit(self: *PostDom) void {
        for (self.sets) |*set| {
            set.deinit();
        }
        if (self.sets.len > 0) self.allocator.free(self.sets);
        if (self.ipdom.len > 0) self.allocator.free(self.ipdom);
        if (self.depth.len > 0) self.allocator.free(self.depth);
    }

    pub fn postdominates(self: *const PostDom, a: u32, b: u32) bool {
        if (b >= self.sets.len or a >= self.sets.len) return false;
        return self.sets[b].isSet(a);
    }

    pub fn merge(self: *const PostDom, a: u32, b: u32) ?u32 {
        const m = self.lca(a, b) orelse return null;
        if (self.virtual_exit) |ve| {
            if (m == ve) return null;
        }
        return m;
    }

    fn lca(self: *const PostDom, a: u32, b: u32) ?u32 {
        if (a >= self.depth.len or b >= self.depth.len) return null;
        var x = a;
        var y = b;
        while (self.depth[x] > self.depth[y]) {
            x = self.ipdom[x] orelse return null;
        }
        while (self.depth[y] > self.depth[x]) {
            y = self.ipdom[y] orelse return null;
        }
        while (x != y) {
            x = self.ipdom[x] orelse return null;
            y = self.ipdom[y] orelse return null;
        }
        return x;
    }
};

/// Compute post-dominator sets and tree.
pub fn computePostDom(allocator: Allocator, cfg: *const CFG, include_exceptions: bool) !PostDom {
    const n: u32 = @intCast(cfg.blocks.len);
    var exits = try collectExitBlocks(allocator, cfg, include_exceptions);
    defer exits.deinit(allocator);

    var rev = try allocator.alloc(std.ArrayListUnmanaged(u32), @intCast(n));
    errdefer {
        for (rev) |*lst| lst.deinit(allocator);
        allocator.free(rev);
    }
    for (rev) |*lst| {
        lst.* = .{};
    }
    var src: u32 = 0;
    while (src < n) : (src += 1) {
        for (cfg.blocks[@intCast(src)].successors) |edge| {
            if (!include_exceptions and edge.edge_type == .exception) continue;
            const tgt = edge.target;
            if (tgt >= n) continue;
            try rev[@intCast(tgt)].append(allocator, src);
        }
    }
    defer {
        for (rev) |*lst| lst.deinit(allocator);
        allocator.free(rev);
    }

    var reachable = try std.DynamicBitSet.initEmpty(allocator, @intCast(n));
    defer reachable.deinit();
    if (exits.items.len > 0) {
        var queue: std.ArrayListUnmanaged(u32) = .{};
        defer queue.deinit(allocator);
        for (exits.items) |eid| {
            if (eid >= n) continue;
            if (!reachable.isSet(@intCast(eid))) {
                reachable.set(@intCast(eid));
                try queue.append(allocator, eid);
            }
        }
        while (queue.items.len > 0) {
            const cur = queue.items[queue.items.len - 1];
            queue.items.len -= 1;
            for (rev[@intCast(cur)].items) |pred| {
                if (pred >= n) continue;
                if (reachable.isSet(@intCast(pred))) continue;
                reachable.set(@intCast(pred));
                try queue.append(allocator, pred);
            }
        }
    }
    var any_unreach = exits.items.len == 0;
    if (!any_unreach) {
        var bid: u32 = 0;
        while (bid < n) : (bid += 1) {
            if (!reachable.isSet(@intCast(bid))) {
                any_unreach = true;
                break;
            }
        }
    }

    var virtual_exit: ?u32 = null;
    var total: u32 = n;
    if (exits.items.len > 1 or any_unreach) {
        virtual_exit = n;
        total = n + 1;
    }

    const total_usize: usize = @intCast(total);
    var sets = try allocator.alloc(std.DynamicBitSet, total_usize);
    errdefer {
        for (sets) |*set| set.deinit();
        allocator.free(sets);
    }
    var ipdom = try allocator.alloc(?u32, total_usize);
    errdefer allocator.free(ipdom);
    var depth = try allocator.alloc(u32, total_usize);
    errdefer allocator.free(depth);

    var is_exit = try std.DynamicBitSet.initEmpty(allocator, total_usize);
    defer is_exit.deinit();
    for (exits.items) |bid| {
        if (bid < n) is_exit.set(@intCast(bid));
    }

    var i: usize = 0;
    while (i < total_usize) : (i += 1) {
        if (virtual_exit != null and i == @as(usize, @intCast(virtual_exit.?))) {
            sets[i] = try std.DynamicBitSet.initEmpty(allocator, total_usize);
            sets[i].set(i);
        } else if (i < n and (!reachable.isSet(i) or (virtual_exit == null and is_exit.isSet(i)))) {
            sets[i] = try std.DynamicBitSet.initEmpty(allocator, total_usize);
            sets[i].set(i);
        } else {
            sets[i] = try std.DynamicBitSet.initFull(allocator, total_usize);
        }
    }

    var scratch = try std.DynamicBitSet.initEmpty(allocator, total_usize);
    defer scratch.deinit();

    var changed = true;
    while (changed) {
        changed = false;
        var bid: u32 = 0;
        while (bid < n) : (bid += 1) {
            if (!reachable.isSet(@intCast(bid))) continue;
            if (virtual_exit == null and is_exit.isSet(@intCast(bid))) continue;
            scratch.setRangeValue(.{ .start = 0, .end = total_usize }, false);
            var has_succ = false;

            for (cfg.blocks[@intCast(bid)].successors) |edge| {
                if (!include_exceptions and edge.edge_type == .exception) continue;
                const tid = edge.target;
                if (tid >= n) continue;
                if (!has_succ) {
                    scratch.setUnion(sets[@intCast(tid)]);
                    has_succ = true;
                } else {
                    scratch.setIntersection(sets[@intCast(tid)]);
                }
            }
            if (!has_succ) {
                if (virtual_exit) |ve| {
                    scratch.setUnion(sets[@intCast(ve)]);
                    has_succ = true;
                }
            }
            scratch.set(@intCast(bid));

            const idx: usize = @intCast(bid);
            if (!scratch.eql(sets[idx])) {
                sets[idx].setRangeValue(.{ .start = 0, .end = total_usize }, false);
                sets[idx].setUnion(scratch);
                changed = true;
            }
        }
    }

    // Compute immediate post-dominator.
    i = 0;
    while (i < total_usize) : (i += 1) {
        if (virtual_exit != null and i == @as(usize, @intCast(virtual_exit.?))) {
            ipdom[i] = null;
            continue;
        }
        var best: ?u32 = null;
        if (i >= n) {
            ipdom[i] = null;
            continue;
        }
        var it = sets[i].iterator(.{});
        while (it.next()) |cand| {
            if (cand == i) continue;
            var ok = true;
            var it2 = sets[i].iterator(.{});
            while (it2.next()) |other| {
                if (other == i or other == cand) continue;
                if (!sets[cand].isSet(other)) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                best = @intCast(cand);
                break;
            }
        }
        ipdom[i] = best;
    }

    // Compute depth from postdom root.
    i = 0;
    while (i < total_usize) : (i += 1) {
        var d: u32 = 0;
        var cur: ?u32 = @intCast(i);
        var steps: u32 = 0;
        while (cur) |c| {
            steps += 1;
            if (steps > total) break;
            const p = ipdom[@intCast(c)] orelse break;
            d += 1;
            cur = p;
        }
        depth[i] = d;
    }

    return PostDom{
        .allocator = allocator,
        .sets = sets,
        .ipdom = ipdom,
        .depth = depth,
        .virtual_exit = virtual_exit,
    };
}

fn collectExitBlocks(
    allocator: Allocator,
    cfg: *const CFG,
    include_exceptions: bool,
) !std.ArrayListUnmanaged(u32) {
    var exits: std.ArrayListUnmanaged(u32) = .{};
    var bid: u32 = 0;
    while (bid < cfg.blocks.len) : (bid += 1) {
        var has_succ = false;
        for (cfg.blocks[@intCast(bid)].successors) |edge| {
            if (!include_exceptions and edge.edge_type == .exception) continue;
            has_succ = true;
            break;
        }
        if (!has_succ) {
            try exits.append(allocator, bid);
        }
    }
    return exits;
}

/// Build a CFG from bytecode.
pub fn buildCFG(allocator: Allocator, bytecode: []const u8, version: Version) !CFG {
    return buildCFGWithLeaders(allocator, bytecode, version, &.{});
}

/// Build a CFG from bytecode with additional leader offsets.
fn buildCFGWithLeaders(
    allocator: Allocator,
    bytecode: []const u8,
    version: Version,
    exception_entries: []const ExceptionEntry,
) !CFG {
    // Step 1: Decode all instructions
    var iter = decoder.InstructionIterator.init(bytecode, version);
    const instructions = try iter.collectAlloc(allocator);
    errdefer allocator.free(instructions);

    var legacy_entries: []ExceptionEntry = &.{};
    const use_legacy = exception_entries.len == 0 and !version.gte(3, 11);
    if (use_legacy) {
        legacy_entries = try collectLegacyExceptionEntries(allocator, instructions, version);
    }
    defer {
        if (legacy_entries.len > 0) allocator.free(legacy_entries);
    }
    const entries = if (use_legacy) legacy_entries else exception_entries;

    if (instructions.len == 0) {
        return CFG{
            .allocator = allocator,
            .blocks = &.{},
            .block_offsets = &.{},
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
    // - Exception handler entry points
    var leaders = std.AutoHashMap(u32, void).init(allocator);
    defer leaders.deinit();

    // Add exception handler targets and range boundaries as leaders
    for (entries) |entry| {
        try leaders.put(entry.target, {});
        // The start and end of exception-protected range should also be leaders
        // This ensures with statements and try blocks have proper block boundaries
        try leaders.put(entry.start, {});
        try leaders.put(entry.end, {});
    }

    // First instruction is always a leader
    try leaders.put(instructions[0].offset, {});

    for (instructions, 0..) |inst, i| {
        // If this is a jump, the target is a leader
        if (inst.jumpTarget(version)) |target| {
            try leaders.put(target, {});
        }

        // If this is a branch or terminator, next instruction (if any) is a leader
        if (inst.isJump() or inst.isBlockTerminator() or inst.opcode == .SETUP_WITH or inst.opcode == .SETUP_ASYNC_WITH) {
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
                    const is_back_jump = (t.opcode == .JUMP_BACKWARD or t.opcode == .JUMP_BACKWARD_NO_INTERRUPT) or
                        (t.opcode == .JUMP_ABSOLUTE and target < t.offset);
                    const edge_type: EdgeType = if (t.isConditionalJump()) blk: {
                        // For POP_JUMP_IF_FALSE/NONE, jump target is the FALSE branch
                        // For POP_JUMP_IF_TRUE/NOT_NONE, jump target is the TRUE branch
                        // For FOR_ITER/FOR_LOOP, jump target is the exhausted/exit path
                        break :blk switch (t.opcode) {
                            .POP_JUMP_IF_FALSE,
                            .POP_JUMP_IF_NONE,
                            .POP_JUMP_FORWARD_IF_FALSE,
                            .POP_JUMP_FORWARD_IF_NONE,
                            .POP_JUMP_BACKWARD_IF_FALSE,
                            .POP_JUMP_BACKWARD_IF_NONE,
                            .FOR_ITER,
                            .FOR_LOOP,
                            .JUMP_IF_FALSE, // Python 3.0
                            .JUMP_IF_FALSE_OR_POP,
                            .JUMP_IF_NOT_EXC_MATCH,
                            => .conditional_false,
                            .POP_JUMP_IF_TRUE,
                            .POP_JUMP_IF_NOT_NONE,
                            .POP_JUMP_FORWARD_IF_TRUE,
                            .POP_JUMP_FORWARD_IF_NOT_NONE,
                            .POP_JUMP_BACKWARD_IF_TRUE,
                            .POP_JUMP_BACKWARD_IF_NOT_NONE,
                            .JUMP_IF_TRUE, // Python 3.0
                            .JUMP_IF_TRUE_OR_POP,
                            => .conditional_true,
                            else => .conditional_true,
                        };
                    } else if (is_back_jump)
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
                const edge_type: EdgeType = if (term) |t| blk: {
                    if (t.isConditionalJump()) {
                        // Fallthrough is the opposite of jump target
                        // FOR_ITER fallthrough is the body (normal path)
                        break :blk switch (t.opcode) {
                            .POP_JUMP_IF_FALSE,
                            .POP_JUMP_IF_NONE,
                            .POP_JUMP_FORWARD_IF_FALSE,
                            .POP_JUMP_FORWARD_IF_NONE,
                            .POP_JUMP_BACKWARD_IF_FALSE,
                            .POP_JUMP_BACKWARD_IF_NONE,
                            .JUMP_IF_FALSE, // Python 3.0
                            .JUMP_IF_FALSE_OR_POP,
                            .JUMP_IF_NOT_EXC_MATCH,
                            => .conditional_true,
                            .POP_JUMP_IF_TRUE,
                            .POP_JUMP_IF_NOT_NONE,
                            .POP_JUMP_FORWARD_IF_TRUE,
                            .POP_JUMP_FORWARD_IF_NOT_NONE,
                            .POP_JUMP_BACKWARD_IF_TRUE,
                            .POP_JUMP_BACKWARD_IF_NOT_NONE,
                            .JUMP_IF_TRUE, // Python 3.0
                            .JUMP_IF_TRUE_OR_POP,
                            => .conditional_false,
                            .FOR_ITER,
                            .FOR_LOOP,
                            => .normal,
                            else => .conditional_false,
                        };
                    }
                    break :blk .normal;
                } else .normal;
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

    const block_offsets = try allocator.alloc(u32, blocks.len);
    errdefer allocator.free(block_offsets);
    for (blocks, 0..) |block, i| {
        block_offsets[i] = block.start_offset;
    }

    var cfg = CFG{
        .allocator = allocator,
        .blocks = blocks,
        .block_offsets = block_offsets,
        .entry = 0,
        .instructions = instructions,
        .version = version,
    };

    if (use_legacy and entries.len > 0) {
        try applyExceptionEntries(allocator, &cfg, entries);
    }

    return cfg;
}

fn collectLegacyExceptionEntries(
    allocator: Allocator,
    instructions: []const Instruction,
    version: Version,
) ![]ExceptionEntry {
    var entries: std.ArrayList(ExceptionEntry) = .{};
    errdefer entries.deinit(allocator);

    const SetupKind = enum { loop, except, finally, with };
    const SetupEntry = struct {
        kind: SetupKind,
        start: u32,
        target: u32,
    };

    var stack: std.ArrayList(SetupEntry) = .{};
    defer stack.deinit(allocator);

    const multiplier: u32 = if (version.gte(3, 10)) 2 else 1;

    const isEarlyReturn = struct {
        fn check(insts: []const Instruction, idx: usize) bool {
            var i = idx + 1;
            while (i < insts.len) : (i += 1) {
                const next = insts[i];
                switch (next.opcode) {
                    .CACHE, .NOP => continue,
                    else => {},
                }
                if (next.isBlockTerminator()) {
                    return switch (next.opcode) {
                        .RETURN_VALUE,
                        .RETURN_CONST,
                        .RAISE_VARARGS,
                        .RERAISE,
                        => true,
                        else => false,
                    };
                }
                if (next.isJump()) return false;
            }
            return false;
        }
    }.check;

    for (instructions, 0..) |inst, inst_idx| {
        // Drop exception setups once we reach their handler target.
        while (stack.items.len > 0) {
            const top = stack.items[stack.items.len - 1];
            switch (top.kind) {
                .except, .finally, .with => {
                    if (inst.offset >= top.target) {
                        _ = stack.pop();
                        continue;
                    }
                },
                else => {},
            }
            break;
        }
        switch (inst.opcode) {
            .SETUP_LOOP => {
                try stack.append(allocator, .{
                    .kind = .loop,
                    .start = inst.offset + inst.size,
                    .target = 0,
                });
            },
            .SETUP_EXCEPT => {
                const target = inst.offset + inst.size + inst.arg * multiplier;
                try stack.append(allocator, .{
                    .kind = .except,
                    // Include SETUP_EXCEPT in protected range to keep try header in same block
                    .start = inst.offset,
                    .target = target,
                });
            },
            .SETUP_FINALLY => {
                const target = inst.offset + inst.size + inst.arg * multiplier;
                try stack.append(allocator, .{
                    .kind = .finally,
                    // Include SETUP_FINALLY in protected range to keep try header in same block
                    .start = inst.offset,
                    .target = target,
                });
            },
            .SETUP_WITH, .SETUP_ASYNC_WITH => {
                const target = inst.offset + inst.size + inst.arg * multiplier;
                try stack.append(allocator, .{
                    .kind = .with,
                    // Include SETUP_WITH in protected range to keep with header in same block
                    .start = inst.offset,
                    .target = target,
                });
            },
            .POP_BLOCK => {
                if (stack.items.len == 0) continue;
                const entry = stack.items[stack.items.len - 1];
                switch (entry.kind) {
                    .except, .finally, .with => {
                        try entries.append(allocator, .{
                            .start = entry.start,
                            .end = inst.offset + inst.size,
                            .target = entry.target,
                            .depth = 0,
                            .push_lasti = false,
                        });
                        var pop = !isEarlyReturn(instructions, inst_idx);
                        if (pop) {
                            var j = inst_idx + 1;
                            while (j < instructions.len) : (j += 1) {
                                const next = instructions[j];
                                switch (next.opcode) {
                                    .CACHE, .NOP => continue,
                                    else => {},
                                }
                                if (next.isJump()) {
                                    if (next.jumpTarget(version)) |tgt| {
                                        if (tgt < entry.target) {
                                            pop = false;
                                        }
                                    }
                                }
                                break;
                            }
                        }
                        if (pop) _ = stack.pop();
                    },
                    else => {
                        _ = stack.pop();
                    },
                }
            },
            else => {},
        }
    }

    return entries.toOwnedSlice(allocator);
}

fn applyExceptionEntries(allocator: Allocator, cfg: *CFG, entries: []const ExceptionEntry) !void {
    if (entries.len == 0) return;

    const EdgeToAdd = struct { from: u32, to: u32 };
    var edges_to_add: std.ArrayList(EdgeToAdd) = .{};
    defer edges_to_add.deinit(allocator);

    for (entries) |entry| {
        const handler_block_ptr = cfg.blockContaining(entry.target);
        var handler_block_id: ?u32 = null;
        if (handler_block_ptr) |ptr| {
            handler_block_id = ptr.id;
        }
        if (handler_block_id) |hid| {
            cfg.blocks[hid].is_exception_handler = true;
        }

        for (cfg.blocks, 0..) |*block, block_idx| {
            if (block.start_offset < entry.end and block.end_offset > entry.start) {
                if (handler_block_id) |hid| {
                    var has_edge = false;
                    for (block.successors) |edge| {
                        if (edge.target == hid and edge.edge_type == .exception) {
                            has_edge = true;
                            break;
                        }
                    }
                    if (!has_edge) {
                        try edges_to_add.append(allocator, .{ .from = @intCast(block_idx), .to = hid });
                    }
                }
            }
        }
    }

    for (edges_to_add.items) |edge_info| {
        const block_idx = edge_info.from;
        const hid = edge_info.to;

        const block = &cfg.blocks[block_idx];
        const old_len = block.successors.len;
        const new_succs = try allocator.alloc(Edge, old_len + 1);
        @memcpy(new_succs[0..old_len], block.successors);
        new_succs[old_len] = .{
            .target = hid,
            .edge_type = .exception,
        };

        if (old_len > 0) {
            allocator.free(block.successors);
        }
        cfg.blocks[block_idx].successors = new_succs;

        const handler = &cfg.blocks[hid];
        const old_preds = handler.predecessors;
        const new_preds = try allocator.alloc(u32, old_preds.len + 1);
        @memcpy(new_preds[0..old_preds.len], old_preds);
        new_preds[old_preds.len] = @intCast(block_idx);

        if (old_preds.len > 0) {
            allocator.free(old_preds);
        }
        cfg.blocks[hid].predecessors = new_preds;
    }
}

// ============================================================================
// Exception Table Parsing (Python 3.11+)
// ============================================================================

/// An exception table entry.
pub const ExceptionEntry = struct {
    /// Inclusive start offset of the protected range.
    start: u32,
    /// Exclusive end offset of the protected range.
    end: u32,
    /// Bytecode offset of the exception handler.
    target: u32,
    /// Stack depth at handler entry.
    depth: u16,
    /// Whether to push the instruction offset (lasti) before the exception.
    push_lasti: bool,
};

/// Parse the exception table (3.11+ format).
/// Note: Exception table stores offsets in instruction units (words).
/// For 3.11+, each instruction is 2 bytes, so offsets are multiplied by 2.
pub fn parseExceptionTable(table: []const u8, allocator: Allocator) ![]ExceptionEntry {
    if (table.len == 0) return &.{};

    var entries: std.ArrayList(ExceptionEntry) = .{};
    errdefer entries.deinit(allocator);

    var pos: usize = 0;
    while (pos < table.len) {
        // First byte must have S bit (bit 7) set
        if ((table[pos] & 0x80) == 0) break;

        // Read start offset (in instruction units)
        const start_result = readVarint7(table, pos);
        pos = start_result.new_pos;
        const start = start_result.value * 2; // Convert to byte offset

        // Read size (end - start, in instruction units)
        const size_result = readVarint7(table, pos);
        pos = size_result.new_pos;
        const size = size_result.value * 2; // Convert to bytes

        // Read target handler offset (in instruction units)
        const target_result = readVarint7(table, pos);
        pos = target_result.new_pos;
        const target = target_result.value * 2; // Convert to byte offset

        // Read combined depth_lasti value
        const depth_lasti_result = readVarint7(table, pos);
        pos = depth_lasti_result.new_pos;
        const depth_lasti = depth_lasti_result.value;

        try entries.append(allocator, .{
            .start = start,
            .end = start + size,
            .target = target,
            .depth = @intCast(depth_lasti >> 1),
            .push_lasti = (depth_lasti & 1) != 0,
        });
    }

    return entries.toOwnedSlice(allocator);
}

/// Read a 7-bit varint from the exception table.
/// Format: SXdddddd where S=start marker, X=extend, d=data bits.
/// Uses big-endian encoding: first byte contributes most significant bits.
fn readVarint7(data: []const u8, start_pos: usize) struct { value: u32, new_pos: usize } {
    var result: u32 = 0;
    var pos = start_pos;

    while (pos < data.len) {
        const byte = data[pos];
        pos += 1;

        // Shift existing result and add new 6 data bits (big-endian)
        result = (result << 6) | @as(u32, byte & 0x3F);

        // X bit (bit 6) not set = last byte of this value
        if ((byte & 0x40) == 0) break;
    }

    return .{ .value = result, .new_pos = pos };
}

/// Build CFG with exception handling information.
pub fn buildCFGWithExceptions(
    allocator: Allocator,
    bytecode: []const u8,
    exception_table: []const u8,
    version: Version,
) !CFG {
    // Parse exception table first (only for 3.11+)
    if (!version.gte(3, 11) or exception_table.len == 0) {
        return try buildCFG(allocator, bytecode, version);
    }

    const entries = try parseExceptionTable(exception_table, allocator);
    defer allocator.free(entries);

    // Build CFG with exception handler offsets as additional leaders
    var cfg = try buildCFGWithLeaders(allocator, bytecode, version, entries);
    errdefer cfg.deinit();

    try applyExceptionEntries(allocator, &cfg, entries);

    return cfg;
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

fn opcodeByte(version: Version, op: Opcode) u8 {
    const table = opcodes.getOpcodeTable(version);
    for (table, 0..) |entry, idx| {
        if (entry == op) return @intCast(idx);
    }
    @panic("opcode not in table");
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
    // POP_JUMP_IF_FALSE is byte 114, target is relative from next instruction
    // Note: POP_JUMP_IF_FALSE has NO cache entries in 3.12
    const bytecode = [_]u8{
        151, 0, // RESUME 0 @ 0
        124, 0, // LOAD_FAST 0 @ 2
        114, 1, // POP_JUMP_IF_FALSE to offset 8 @ 4
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

test "cfg jump absolute back edge" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const v38 = Version.init(3, 8);

    // Simple backward jump to form a loop header.
    const bytecode = [_]u8{
        opcodeByte(v38, .LOAD_CONST), 0, // offset 0
        opcodeByte(v38, .JUMP_ABSOLUTE), 0, // offset 2 -> jump back to 0
    };

    var cfg = try buildCFG(allocator, &bytecode, v38);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.blocks.len);
    try testing.expectEqual(@as(usize, 1), cfg.blocks[0].successors.len);
    try testing.expectEqual(EdgeType.loop_back, cfg.blocks[0].successors[0].edge_type);
    try testing.expect(cfg.blocks[0].is_loop_header);
}

test "exception table parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simple exception table with one entry:
    // start=0, size=10, target=20, depth=1, lasti=0
    // depth_lasti = (1 << 1) | 0 = 2
    //
    // Encoding (all values fit in single bytes, so no extend bits):
    // start: 0x80 | 0 = 0x80 (S=1, X=0, d=0)
    // size: 10 = 0x0A
    // target: 20 = 0x14
    // depth_lasti: 2 = 0x02
    const table = [_]u8{ 0x80, 0x0A, 0x14, 0x02 };

    const entries = try parseExceptionTable(&table, allocator);
    defer allocator.free(entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u32, 0), entries[0].start);
    try testing.expectEqual(@as(u32, 20), entries[0].end); // 10 words * 2 = 20 bytes
    try testing.expectEqual(@as(u32, 40), entries[0].target); // 20 words * 2 = 40 bytes
    try testing.expectEqual(@as(u16, 1), entries[0].depth);
    try testing.expectEqual(false, entries[0].push_lasti);
}

test "exception table varint" {
    const testing = std.testing;

    // Test varint with extend bit (big-endian: high bits first)
    // Value 100 = 1 * 64 + 36 = (1 << 6) | 36
    // First byte: d=1, X=1 (extend) -> 0x41
    // Second byte: d=36, X=0 -> 0x24
    // Decoding: (1 << 6) | 36 = 100
    const result = readVarint7(&[_]u8{ 0x41, 0x24 }, 0);
    try testing.expectEqual(@as(u32, 100), result.value);
    try testing.expectEqual(@as(usize, 2), result.new_pos);
}
