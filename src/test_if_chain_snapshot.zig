//! Snapshot test for chained compare with terminal else.

const std = @import("std");
const testing = std.testing;
const OhSnap = @import("ohsnap");

const pyc = @import("pyc.zig");
const tu = @import("test_utils.zig");
const Version = @import("opcodes.zig").Version;

fn hexVal(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn decodeHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = try hexVal(hex[i * 2]);
        const lo = try hexVal(hex[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

test "snapshot chained compare guard 3.9" {
    const allocator = testing.allocator;
    const version = Version.init(3, 9);

    const code_hex = "74007c0083017230640174017c008301040003006b00722064026b00722a6e0401006e067c007d017134640353006e046403530064045300";
    const bytecode = try decodeHex(allocator, code_hex);

    const consts = [_]pyc.Object{
        .none,
        .{ .int = .{ .small = 0 } },
        .{ .int = .{ .small = 99999 } },
        .false_val,
        .true_val,
    };

    const code = tu.allocCodeWithNames(
        allocator,
        "f",
        &[_][]const u8{ "x", "y" },
        &[_][]const u8{ "is_int_m", "int" },
        &consts,
        bytecode,
        1,
    ) catch |err| {
        allocator.free(bytecode);
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
        \\[]const u8
        \\  "def f(x):
        \\    if is_int_m(x) and 0 < int(x) < 99999:
        \\        y = x
        \\    else:
        \\        return False
        \\    return True
        \\"
    ).expectEqual(output);
}
