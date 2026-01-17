//! Snapshot tests for boat-main regressions (3.9).

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const Version = @import("opcodes.zig").Version;

fn runSnapshot(
    comptime src: std.builtin.SourceLocation,
    path: []const u8,
    comptime expected: []const u8,
) !void {
    const allocator = testing.allocator;

    var module = pyc.Module.init(allocator);
    defer module.deinit();
    try module.loadFromFile(path);

    const code = module.code orelse {
        try testing.expect(false);
        return;
    };
    const version = Version.init(@intCast(module.major_ver), @intCast(module.minor_ver));

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    try decompile.decompileToSource(allocator, code, version, output.writer(allocator));

    const oh = OhSnap{};
    try oh.snap(src, expected).expectEqual(output.items);
}

test "snapshot loop guard 3.9" {
    try runSnapshot(@src(), "test/corpus/loop_guard.3.9.pyc",
        \\[]u8
        \\  "import sys
        \\class Bdb:
        \\    __module__ = __name__
        \\    __qualname__ = 'Bdb'
        \\    def _set_stopinfo(self, *args, **kwargs):
        \\        pass
        \\    def set_continue(self):
        \\        self._set_stopinfo(self.botframe, None, -1)
        \\        if self.breaks:
        \\            pass
        \\        else:
        \\            sys.settrace(None)
        \\            frame = sys._getframe().f_back
        \\            while frame and frame is not self.botframe:
        \\                del frame.f_trace
        \\                frame = frame.f_back
        \\def del_subscr(d):
        \\    del d['x']
        \\"
    );
}

test "snapshot relative import 3.9" {
    try runSnapshot(@src(), "test/corpus/relative_import.3.9.pyc",
        \\[]u8
        \\  "from . import foo
        \\from .bar import baz
        \\from ..pkg import qux
        \\"
    );
}

test "snapshot future docstring 3.9" {
    try runSnapshot(@src(), "test/corpus/future_docstring.3.9.pyc",
        \\[]u8
        \\  "'Docstring for future import test.'
        \\from __future__ import annotations
        \\value = 1
        \\"
    );
}
