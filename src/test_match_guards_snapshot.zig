//! Snapshot test for match guards decompilation.

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const Version = @import("opcodes.zig").Version;

test "snapshot match guards 3.14" {
    const allocator = testing.allocator;

    var module: pyc.Module = undefined;
    module.init(allocator);
    defer module.deinit();
    try module.loadFromFile("test/corpus/match_guards.3.14.pyc");

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
        \\  "def guard_simple(x):
        \\    match x:
        \\        case n if n < 0:
        \\            return 'neg'
        \\        case n if n == 0:
        \\            return 'zero'
        \\        case n if n > 0:
        \\            return 'pos'
        \\        case _:
        \\            return 'other'
        \\def guard_sequence(x):
        \\    match x:
        \\        case [a, b] if a < b:
        \\            return 'asc'
        \\        case [a, b] if a > b:
        \\            return 'desc'
        \\        case [a, b] if a == b:
        \\            return 'eq'
        \\        case _:
        \\            return 'nope'
        \\def guard_mapping(x):
        \\    match x:
        \\        case {'val': v} if v > 0:
        \\            return 'positive'
        \\        case {'val': v} if v < 0:
        \\            return 'negative'
        \\        case {'val': 0}:
        \\            return 'zero'
        \\        case _:
        \\            return 'unknown'
        \\class Point:
        \\    __firstlineno__ = 36
        \\    __unknown__ = locals()
        \\    def __init__(self, x, y):
        \\        self.x = x
        \\        self.y = y
        \\    __static_attributes__ = ('x', 'y')
        \\    __classdictcell__ = __classdict__
        \\def guard_class(p):
        \\    match p:
        \\        case Point(x=x, y=y) if x == y:
        \\            return 'diag'
        \\        case Point(x=x, y=y) if x < y:
        \\            return 'up'
        \\        case Point(x=x, y=y) if x > y:
        \\            return 'down'
        \\        case _:
        \\            return 'other'
        \\def guard_or(x):
        \\    match x:
        \\        case 1 | 3 | 5 if x % 2 == 1:
        \\            return 'odd'
        \\        case 2 | 4 | 6 if x % 2 == 0:
        \\            return 'even'
        \\        case _:
        \\            return 'other'
        \\def guard_as(x):
        \\    match x:
        \\        case [a, b] as seq if len(seq) == 2 and a != b:
        \\            return seq
        \\        case [a, [b, c]] if a < b < c:
        \\            return (a, b, c)
        \\        case _:
        \\            return None
        \\"
    ).expectEqual(output.items);
}
