const std = @import("std");
const testing = std.testing;

const decompile = @import("decompile.zig");
const opcodes = @import("opcodes.zig");
const pyc = @import("pyc.zig");
const tu = @import("test_utils.zig");

const Version = opcodes.Version;
const OpArg = tu.OpArg;

test "decompile list extend const tuple" {
    const allocator = testing.allocator;
    const version = Version.init(3, 10);

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try tu.dupeStrings(allocator, &[_][]const u8{"x"});

    const tuple_items = try allocator.alloc(pyc.Object, 2);
    tuple_items[0] = .{ .int = pyc.Int.fromI64(1) };
    tuple_items[1] = .{ .int = pyc.Int.fromI64(2) };

    const consts = try allocator.alloc(pyc.Object, 2);
    consts[0] = .{ .tuple = tuple_items };
    consts[1] = .none;
    module.consts = consts;

    const module_ops = [_]OpArg{
        .{ .op = .BUILD_LIST, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .LIST_EXTEND, .arg = 1 },
        .{ .op = .STORE_NAME, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    module.code = try tu.emitOpsOwned(allocator, version, &module_ops);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompile.decompileToSource(allocator, &module, version, out.writer(allocator));
    const output: []const u8 = out.items;

    try testing.expectEqualStrings("x = [1, 2]\n", output);
}
