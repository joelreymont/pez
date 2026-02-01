const std = @import("std");
const cfg_mod = @import("cfg.zig");

/// Dominator tree and natural loop analysis.
pub const DomTree = struct {
    allocator: std.mem.Allocator,
    /// Immediate dominator for each block. idom[i] = immediate dominator of block i.
    /// Entry block (0) has idom = 0 (dominates itself).
    /// Unreachable blocks have idom[i] = i.
    idom: []u32,
    /// For each loop header, the set of blocks in that loop's body.
    loop_bodies: std.AutoHashMap(u32, std.DynamicBitSet),
    /// Number of blocks.
    num_blocks: u32,

    pub fn init(allocator: std.mem.Allocator, cfg: *const cfg_mod.CFG) !DomTree {
        const num_blocks: u32 = @intCast(cfg.blocks.len);
        if (num_blocks == 0) {
            return DomTree{
                .allocator = allocator,
                .idom = &.{},
                .loop_bodies = std.AutoHashMap(u32, std.DynamicBitSet).init(allocator),
                .num_blocks = 0,
            };
        }

        // Compute dominators using the Cooper-Harvey-Kennedy algorithm
        const idom = try computeDominators(allocator, cfg, num_blocks);

        // Find natural loops
        var loop_bodies = std.AutoHashMap(u32, std.DynamicBitSet).init(allocator);
        try findNaturalLoops(allocator, cfg, idom, num_blocks, &loop_bodies);

        return DomTree{
            .allocator = allocator,
            .idom = idom,
            .loop_bodies = loop_bodies,
            .num_blocks = num_blocks,
        };
    }

    pub fn deinit(self: *DomTree) void {
        if (self.idom.len > 0) {
            self.allocator.free(self.idom);
        }
        var it = self.loop_bodies.valueIterator();
        while (it.next()) |bitset| {
            bitset.deinit();
        }
        self.loop_bodies.deinit();
    }

    /// Returns true if block `a` dominates block `b`.
    /// A block dominates itself.
    pub fn dominates(self: *const DomTree, a: u32, b: u32) bool {
        return dominatesIdom(self.idom, self.num_blocks, a, b);
    }

    /// Returns true if `block` is in the loop with header `header`.
    pub fn isInLoop(self: *const DomTree, block: u32, header: u32) bool {
        if (block >= self.num_blocks) return false;
        if (self.loop_bodies.get(header)) |body| {
            return body.isSet(@intCast(block));
        }
        return false;
    }

    /// Get the set of blocks in a loop body, or null if not a loop header.
    pub fn getLoopBody(self: *const DomTree, header: u32) ?*const std.DynamicBitSet {
        return if (self.loop_bodies.getPtr(header)) |ptr| ptr else null;
    }

    /// Get all loop headers.
    /// Caller owns the returned slice.
    pub fn getLoopHeaders(self: *const DomTree) ![]const u32 {
        var headers: std.ArrayListUnmanaged(u32) = .{};
        errdefer headers.deinit(self.allocator);
        var it = self.loop_bodies.keyIterator();
        while (it.next()) |key| {
            try headers.append(self.allocator, key.*);
        }
        return headers.toOwnedSlice(self.allocator);
    }
};

fn dominatesIdom(idom: []const u32, num_blocks: u32, a: u32, b: u32) bool {
    if (a >= num_blocks or b >= num_blocks) return false;
    if (a == b) return true;
    const b_idx: usize = @intCast(b);
    if (b != 0 and idom[b_idx] == b) return false;

    var current = b;
    while (current != 0) {
        const parent = idom[@intCast(current)];
        if (parent == a) return true;
        if (parent == current) break;
        current = parent;
    }

    return a == 0;
}

fn computeReversePostOrder(allocator: std.mem.Allocator, cfg: *const cfg_mod.CFG, num_blocks: u32) ![]u32 {
    if (num_blocks == 0) return &.{};
    const count: usize = @intCast(num_blocks);

    var visited = try std.DynamicBitSet.initEmpty(allocator, count);
    defer visited.deinit();

    var postorder: std.ArrayListUnmanaged(u32) = .{};
    errdefer postorder.deinit(allocator);

    var stack: std.ArrayListUnmanaged(struct { node: u32, next_idx: usize }) = .{};
    defer stack.deinit(allocator);

    visited.set(0);
    try stack.append(allocator, .{ .node = 0, .next_idx = 0 });

    while (stack.items.len > 0) {
        var frame = &stack.items[stack.items.len - 1];
        const node_idx: usize = @intCast(frame.node);
        const block = &cfg.blocks[node_idx];

        if (frame.next_idx < block.successors.len) {
            const edge = block.successors[frame.next_idx];
            frame.next_idx += 1;

            if (edge.target >= num_blocks) continue;
            const succ_idx: usize = @intCast(edge.target);
            if (!visited.isSet(succ_idx)) {
                visited.set(succ_idx);
                try stack.append(allocator, .{ .node = edge.target, .next_idx = 0 });
            }
        } else {
            const node = frame.node;
            _ = stack.pop();
            try postorder.append(allocator, node);
        }
    }

    std.mem.reverse(u32, postorder.items);
    return postorder.toOwnedSlice(allocator);
}

fn intersectIdom(idom: []const u32, rpo_index: []const u32, a: u32, b: u32) u32 {
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

/// Compute immediate dominators using the Cooper-Harvey-Kennedy algorithm.
fn computeDominators(allocator: std.mem.Allocator, cfg: *const cfg_mod.CFG, num_blocks: u32) ![]u32 {
    const count: usize = @intCast(num_blocks);
    const undef = std.math.maxInt(u32);

    var idom = try allocator.alloc(u32, count);
    @memset(idom, undef);

    const rpo = try computeReversePostOrder(allocator, cfg, num_blocks);
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

            for (cfg.blocks[node_idx].predecessors) |pred| {
                if (idom[@intCast(pred)] == undef) continue;
                if (new_idom == null) {
                    new_idom = pred;
                } else {
                    new_idom = intersectIdom(idom, rpo_index, pred, new_idom.?);
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

/// Find natural loops by identifying back edges and computing loop bodies.
fn findNaturalLoops(
    allocator: std.mem.Allocator,
    cfg: *const cfg_mod.CFG,
    idom: []const u32,
    num_blocks: u32,
    loop_bodies: *std.AutoHashMap(u32, std.DynamicBitSet),
) !void {
    const count: usize = @intCast(num_blocks);
    // Find back edges: edge B→H where H dominates B
    for (cfg.blocks, 0..) |block, b| {
        for (block.successors) |edge| {
            const h = edge.target;
            const tail: u32 = @intCast(b);
            if (h < num_blocks and dominatesIdom(idom, num_blocks, h, tail)) {
                // Back edge found: b → h
                // Compute loop body: all nodes that can reach b without going through h
                var body = try std.DynamicBitSet.initEmpty(allocator, count);
                body.set(@intCast(h)); // Header is always in loop

                if (tail != h) {
                    // Use reverse DFS from b to find all nodes that reach b
                    var worklist: std.ArrayListUnmanaged(u32) = .{};
                    defer worklist.deinit(allocator);

                    try worklist.append(allocator, tail);
                    body.set(@intCast(tail));

                    while (worklist.items.len > 0) {
                        const node = worklist.pop() orelse return error.UnexpectedEmptyWorklist;
                        // Add all predecessors that aren't already in body
                        const node_idx: usize = @intCast(node);
                        for (cfg.blocks[node_idx].predecessors) |pred| {
                            const pred_idx: usize = @intCast(pred);
                            if (!body.isSet(pred_idx)) {
                                body.set(pred_idx);
                                if (pred != h) {
                                    try worklist.append(allocator, pred);
                                }
                            }
                        }
                    }
                }

                // Merge with existing loop body if header already has one
                if (loop_bodies.getPtr(h)) |existing| {
                    existing.setUnion(body);
                    body.deinit();
                } else {
                    try loop_bodies.put(h, body);
                }
            }
        }
    }
}

test "dominator simple" {
    const allocator = std.testing.allocator;
    const version = cfg_mod.Version.init(3, 12);

    // Build a simple CFG: 0 → 1 → 2
    const block_offsets = &[_]u32{ 0, 0, 0 };
    var cfg = cfg_mod.CFG{
        .allocator = allocator,
        .blocks = &.{},
        .block_offsets = @constCast(block_offsets),
        .entry = 0,
        .instructions = &.{},
        .exception_entries = &.{},
        .version = version,
    };

    var succ_0 = [_]cfg_mod.Edge{.{ .target = 1, .edge_type = .normal }};
    var succ_1 = [_]cfg_mod.Edge{.{ .target = 2, .edge_type = .normal }};
    var no_edges = [_]cfg_mod.Edge{};
    var preds_0 = [_]u32{};
    var preds_1 = [_]u32{0};
    var preds_2 = [_]u32{1};

    var blocks: [3]cfg_mod.BasicBlock = undefined;
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
        .start_offset = 0,
        .end_offset = 0,
        .instructions = &.{},
        .successors = succ_1[0..],
        .predecessors = preds_1[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    blocks[2] = .{
        .id = 2,
        .start_offset = 0,
        .end_offset = 0,
        .instructions = &.{},
        .successors = no_edges[0..],
        .predecessors = preds_2[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    cfg.blocks = &blocks;

    var dom = try DomTree.init(allocator, &cfg);
    defer dom.deinit();

    // 0 dominates everything
    try std.testing.expect(dom.dominates(0, 0));
    try std.testing.expect(dom.dominates(0, 1));
    try std.testing.expect(dom.dominates(0, 2));

    // 1 dominates 2 but not 0
    try std.testing.expect(!dom.dominates(1, 0));
    try std.testing.expect(dom.dominates(1, 1));
    try std.testing.expect(dom.dominates(1, 2));

    // 2 only dominates itself
    try std.testing.expect(!dom.dominates(2, 0));
    try std.testing.expect(!dom.dominates(2, 1));
    try std.testing.expect(dom.dominates(2, 2));

    const headers = try dom.getLoopHeaders();
    defer allocator.free(headers);
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}

test "dominator unreachable block" {
    const allocator = std.testing.allocator;
    const version = cfg_mod.Version.init(3, 12);

    // CFG: 0 → 1, block 2 is unreachable.
    const block_offsets = &[_]u32{ 0, 0, 0 };
    var cfg = cfg_mod.CFG{
        .allocator = allocator,
        .blocks = &.{},
        .block_offsets = @constCast(block_offsets),
        .entry = 0,
        .instructions = &.{},
        .exception_entries = &.{},
        .version = version,
    };

    var succ_0 = [_]cfg_mod.Edge{.{ .target = 1, .edge_type = .normal }};
    var no_edges = [_]cfg_mod.Edge{};
    var preds_0 = [_]u32{};
    var preds_1 = [_]u32{0};
    var preds_2 = [_]u32{};

    var blocks: [3]cfg_mod.BasicBlock = undefined;
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
        .start_offset = 0,
        .end_offset = 0,
        .instructions = &.{},
        .successors = no_edges[0..],
        .predecessors = preds_1[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    blocks[2] = .{
        .id = 2,
        .start_offset = 0,
        .end_offset = 0,
        .instructions = &.{},
        .successors = no_edges[0..],
        .predecessors = preds_2[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    cfg.blocks = &blocks;

    var dom = try DomTree.init(allocator, &cfg);
    defer dom.deinit();

    try std.testing.expect(dom.dominates(0, 1));
    try std.testing.expect(!dom.dominates(0, 2));
    try std.testing.expect(dom.dominates(2, 2));
}

test "dominator with loop" {
    const allocator = std.testing.allocator;
    const version = cfg_mod.Version.init(3, 12);

    // CFG with loop: 0 → 1 → 2 → 1 (back edge), 1 → 3
    const block_offsets = &[_]u32{ 0, 0, 0, 0 };
    var cfg = cfg_mod.CFG{
        .allocator = allocator,
        .blocks = &.{},
        .block_offsets = @constCast(block_offsets),
        .entry = 0,
        .instructions = &.{},
        .exception_entries = &.{},
        .version = version,
    };

    var succ_0 = [_]cfg_mod.Edge{.{ .target = 1, .edge_type = .normal }};
    var succ_1 = [_]cfg_mod.Edge{
        .{ .target = 2, .edge_type = .conditional_true },
        .{ .target = 3, .edge_type = .conditional_false },
    };
    var succ_2 = [_]cfg_mod.Edge{.{ .target = 1, .edge_type = .loop_back }};
    var no_edges = [_]cfg_mod.Edge{};
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
        .start_offset = 0,
        .end_offset = 0,
        .instructions = &.{},
        .successors = succ_1[0..],
        .predecessors = preds_1[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    blocks[2] = .{
        .id = 2,
        .start_offset = 0,
        .end_offset = 0,
        .instructions = &.{},
        .successors = succ_2[0..],
        .predecessors = preds_2[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    blocks[3] = .{
        .id = 3,
        .start_offset = 0,
        .end_offset = 0,
        .instructions = &.{},
        .successors = no_edges[0..],
        .predecessors = preds_3[0..],
        .is_exception_handler = false,
        .is_loop_header = false,
    };
    cfg.blocks = &blocks;

    var dom = try DomTree.init(allocator, &cfg);
    defer dom.deinit();

    // 1 is loop header, should dominate 2
    try std.testing.expect(dom.dominates(1, 2));

    // Block 2 should be in loop with header 1
    try std.testing.expect(dom.isInLoop(2, 1));
    try std.testing.expect(dom.isInLoop(1, 1)); // Header is in its own loop

    // Block 3 should NOT be in the loop
    try std.testing.expect(!dom.isInLoop(3, 1));
}
