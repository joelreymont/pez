//! Snapshot tests for Python 2.x exec/slice/convert opcodes.

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const tu = @import("test_utils.zig");
const pyc = tu.pyc;

test "snapshot py2 slice exec convert" {
    const allocator = testing.allocator;
    const version = tu.Version.init(2, 7);

    const exec_src = try allocator.dupe(u8, "x=1");
    const consts = [_]pyc.Object{
        .{ .int = .{ .small = 1 } },
        .{ .string = exec_src },
        .none,
    };

    const names = [_][]const u8{ "a", "start", "stop" };
    const ops = [_]tu.OpArg{
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .SLICE_0, .arg = 0 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .LOAD_NAME, .arg = 1 },
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .STORE_SLICE_1, .arg = 0 },
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .LOAD_NAME, .arg = 2 },
        .{ .op = .DELETE_SLICE_2, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .EXEC_STMT, .arg = 0 },
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .UNARY_CONVERT, .arg = 0 },
        .{ .op = .POP_TOP, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE, .arg = 0 },
    };

    const bytecode = try tu.emitOpsOwned(allocator, version, &ops);
    const code = tu.allocCodeWithNames(allocator, "<module>", &.{}, names[0..], &consts, bytecode, 0) catch |err| {
        allocator.free(exec_src);
        return err;
    };
    defer {
        code.deinit();
        allocator.destroy(code);
    }

    const output = try tu.renderModule(allocator, code, version);
    defer allocator.free(output);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "a[:]
        \\a[start:] = 1
        \\del a[:stop]
        \\exec 'x=1'
        \\`a`
        \\"
    ).expectEqual(output);
}
