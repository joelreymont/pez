const std = @import("std");
const cfg = @import("../src/cfg.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.next();
    const n = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 2000;
    const extra = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 4;
    var iters = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 5;
    if (iters == 0) iters = 1;

    var succ_lists = try allocator.alloc(std.ArrayListUnmanaged(u32), n);
    defer {
        for (succ_lists) |*lst| lst.deinit(allocator);
        allocator.free(succ_lists);
    }
    var pred_lists = try allocator.alloc(std.ArrayListUnmanaged(u32), n);
    defer {
        for (pred_lists) |*lst| lst.deinit(allocator);
        allocator.free(pred_lists);
    }

    for (succ_lists) |*lst| lst.* = .{};
    for (pred_lists) |*lst| lst.* = .{};

    var prng = std.rand.DefaultPrng.init(0x9e3779b97f4a7c15);
    const rand = prng.random();

    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const tgt: u32 = @intCast(i + 1);
        try succ_lists[i].append(allocator, tgt);
        try pred_lists[i + 1].append(allocator, @intCast(i));
    }

    i = 0;
    while (i < n) : (i += 1) {
        var k: usize = 0;
        while (k < extra) : (k += 1) {
            const tgt = rand.uintLessThan(usize, n);
            if (tgt == i) continue;
            try succ_lists[i].append(allocator, @intCast(tgt));
            try pred_lists[tgt].append(allocator, @intCast(i));
        }
    }

    var succs = try allocator.alloc([]const u32, n);
    errdefer allocator.free(succs);
    var preds = try allocator.alloc([]const u32, n);
    errdefer allocator.free(preds);

    i = 0;
    while (i < n) : (i += 1) {
        succs[i] = try succ_lists[i].toOwnedSlice(allocator);
        preds[i] = try pred_lists[i].toOwnedSlice(allocator);
    }
    defer {
        for (succs) |s| if (s.len > 0) allocator.free(s);
        for (preds) |p| if (p.len > 0) allocator.free(p);
        allocator.free(succs);
        allocator.free(preds);
    }

    var timer = try std.time.Timer.start();
    var iter: usize = 0;
    while (iter < iters) : (iter += 1) {
        const idom = try cfg.postIdomFrom(allocator, succs, preds, 0);
        allocator.free(idom);
    }
    const ns = timer.read();
    const per = ns / iters;

    const out = std.fs.File.stdout().writer();
    try out.print("nodes={d} extra={d} iters={d} total_ns={d} per_ns={d}\n", .{ n, extra, iters, ns, per });
}
