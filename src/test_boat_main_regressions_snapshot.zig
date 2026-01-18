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

test "snapshot import from group 3.9" {
    try runSnapshot(@src(), "test/corpus/import_from_group.3.9.pyc",
        \\[]u8
        \\  "from pkg import a, b as c, d
        \\from . import local_a, local_b as lb
        \\from ..parent import x, y as yy
        \\from mod import *
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

test "snapshot module if prelude 3.9" {
    try runSnapshot(@src(), "test/corpus/module_if_prelude.3.9.pyc",
        \\[]u8
        \\  "x = 1
        \\y = 2
        \\if x:
        \\    y = 3
        \\else:
        \\    y = 4
        \\"
    );
}

test "snapshot if return fallthrough 3.9" {
    try runSnapshot(@src(), "test/corpus/if_return_fallthrough.3.9.pyc",
        \\[]u8
        \\  "def f(x):
        \\    if x:
        \\        return 1
        \\    else:
        \\        return 2
        \\"
    );
}

test "snapshot if return else fallthrough 3.9" {
    try runSnapshot(@src(), "test/corpus/if_else_return_fallthrough.3.9.pyc",
        \\[]u8
        \\  "def f(x):
        \\    if x:
        \\        y = 1
        \\    else:
        \\        return 2
        \\    return y
        \\"
    );
}

test "snapshot try import 3.9" {
    try runSnapshot(@src(), "test/corpus/try_import.3.9.pyc",
        \\[]u8
        \\  "try:
        \\    import zlib
        \\except ImportError as err:
        \\    zlib = None
        \\    err = None
        \\else:
        \\    zlib = zlib
        \\"
    );
}
