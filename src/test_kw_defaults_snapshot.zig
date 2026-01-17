//! Snapshot test for kw-only defaults decompilation.

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const Version = @import("opcodes.zig").Version;

test "snapshot kw defaults 3.14" {
    const allocator = testing.allocator;

    var module = pyc.Module.init(allocator);
    defer module.deinit();
    try module.loadFromFile("test/corpus/kw_defaults.3.14.pyc");

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
        \\def kw_defaults(a, *, b = 1, c = 'x', d = None):
        \\    return (a, b, c, d)
        \\"
    ).expectEqual(output.items);
}
