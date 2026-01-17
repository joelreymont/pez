//! Snapshot test for legacy SETUP_WITH context extraction (Python 3.9).

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const Version = @import("opcodes.zig").Version;

test "snapshot with legacy 3.9" {
    const allocator = testing.allocator;

    var module = pyc.Module.init(allocator);
    defer module.deinit();
    try module.loadFromFile("test/corpus/with_legacy.3.9.pyc");

    const code = module.code orelse {
        try testing.expect(false);
        return;
    };
    const version = Version.init(@intCast(module.major_ver), @intCast(module.minor_ver));

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    try decompile.decompileToSource(allocator, code, version, output.writer(allocator));

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "from __future__ import annotations
        \\def with_open(path):
        \\    with open(path, 'rb') as f:
        \\        pass
        \\"
    ).expectEqual(output.items);
}
