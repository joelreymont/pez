const std = @import("std");
const testing = std.testing;

const decompile = @import("decompile.zig");
const opcodes = @import("opcodes.zig");
const pyc = @import("pyc.zig");
const tu = @import("test_utils.zig");

const Version = opcodes.Version;
const OpArg = tu.OpArg;

test "ternary mixed boolop condition" {
    const allocator = testing.allocator;
    const version = Version.init(3, 9);

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try tu.dupeStrings(allocator, &[_][]const u8{ "a", "b", "c", "x" });

    const consts = try allocator.alloc(pyc.Object, 3);
    consts[0] = .{ .int = pyc.Int.fromI64(1) };
    consts[1] = .{ .int = pyc.Int.fromI64(2) };
    consts[2] = .none;
    module.consts = consts;

    const module_ops = [_]OpArg{
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 8 },
        .{ .op = .LOAD_NAME, .arg = 1 },
        .{ .op = .POP_JUMP_IF_TRUE, .arg = 12 },
        .{ .op = .LOAD_NAME, .arg = 2 },
        .{ .op = .POP_JUMP_IF_FALSE, .arg = 16 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .JUMP_FORWARD, .arg = 2 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .STORE_NAME, .arg = 3 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    module.code = try tu.emitOpsOwned(allocator, version, &module_ops);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompile.decompileToSource(allocator, &module, version, out.writer(allocator));
    const output: []const u8 = out.items;

    try testing.expectEqualStrings("x = 1 if a and b or c else 2\n", output);
}

test "boolop or_pop chain" {
    const allocator = testing.allocator;
    const version = Version.init(3, 7);

    const func_ops = [_]OpArg{
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .JUMP_IF_FALSE_OR_POP, .arg = 14 },
        .{ .op = .LOAD_FAST, .arg = 1 },
        .{ .op = .POP_JUMP_IF_TRUE, .arg = 12 },
        .{ .op = .LOAD_FAST, .arg = 2 },
        .{ .op = .JUMP_IF_FALSE_OR_POP, .arg = 14 },
        .{ .op = .LOAD_FAST, .arg = 3 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    const func_code = try tu.allocCodeFromOps(
        allocator,
        version,
        "are_instructions_equal",
        &[_][]const u8{ "a", "b", "c", "d" },
        &[_]pyc.Object{},
        &func_ops,
        4,
    );

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try tu.dupeStrings(allocator, &[_][]const u8{"are_instructions_equal"});

    const consts = try allocator.alloc(pyc.Object, 3);
    consts[0] = .{ .code = func_code };
    consts[1] = .{ .string = try allocator.dupe(u8, "are_instructions_equal") };
    consts[2] = .none;
    module.consts = consts;

    const module_ops = [_]OpArg{
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .MAKE_FUNCTION, .arg = 0 },
        .{ .op = .STORE_NAME, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    module.code = try tu.emitOpsOwned(allocator, version, &module_ops);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompile.decompileToSource(allocator, &module, version, out.writer(allocator));
    const output: []const u8 = out.items;

    try testing.expectEqualStrings(
        \\def are_instructions_equal(a, b, c, d):
        \\    return a and (b or c) and d
        \\
    , output);
}

test "boolop or_pop or chain" {
    const allocator = testing.allocator;
    const version = Version.init(3, 7);

    const func_ops = [_]OpArg{
        .{ .op = .LOAD_FAST, .arg = 0 },
        .{ .op = .JUMP_IF_TRUE_OR_POP, .arg = 10 },
        .{ .op = .LOAD_FAST, .arg = 1 },
        .{ .op = .JUMP_IF_TRUE_OR_POP, .arg = 10 },
        .{ .op = .LOAD_FAST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    const func_code = try tu.allocCodeFromOps(
        allocator,
        version,
        "any_true",
        &[_][]const u8{ "a", "b", "c" },
        &[_]pyc.Object{},
        &func_ops,
        3,
    );

    var module = pyc.Code{
        .allocator = allocator,
    };
    defer module.deinit();

    module.name = try allocator.dupe(u8, "<module>");
    module.names = try tu.dupeStrings(allocator, &[_][]const u8{"any_true"});

    const consts = try allocator.alloc(pyc.Object, 3);
    consts[0] = .{ .code = func_code };
    consts[1] = .{ .string = try allocator.dupe(u8, "any_true") };
    consts[2] = .none;
    module.consts = consts;

    const module_ops = [_]OpArg{
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .MAKE_FUNCTION, .arg = 0 },
        .{ .op = .STORE_NAME, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };
    module.code = try tu.emitOpsOwned(allocator, version, &module_ops);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try decompile.decompileToSource(allocator, &module, version, out.writer(allocator));
    const output: []const u8 = out.items;

    try testing.expectEqualStrings(
        \\def any_true(a, b, c):
        \\    return a or b or c
        \\
    , output);
}
