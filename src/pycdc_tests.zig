//! Integration tests using pycdc test suite.

const std = @import("std");
const testing = std.testing;
const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const opcodes = @import("opcodes.zig");

const Version = opcodes.Version;

fn parseVersionPart(part: []const u8) !u8 {
    return if (std.fmt.parseInt(u8, part, 10)) |value| value else |_| return error.InvalidFilename;
}

fn parsePycVersion(filename: []const u8) !Version {
    var it = std.mem.splitScalar(u8, filename, '.');
    var third_last: ?[]const u8 = null;
    var second_last: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    while (it.next()) |seg| {
        third_last = second_last;
        second_last = last;
        last = seg;
    }

    const ext = last orelse return error.InvalidFilename;
    const minor_str = second_last orelse return error.InvalidFilename;
    const major_str = third_last orelse return error.InvalidFilename;
    if (!std.mem.eql(u8, ext, "pyc")) return error.InvalidFilename;
    if (major_str.len == 0 or minor_str.len == 0) return error.InvalidFilename;
    for (major_str) |c| if (!std.ascii.isDigit(c)) return error.InvalidFilename;
    for (minor_str) |c| if (!std.ascii.isDigit(c)) return error.InvalidFilename;

    const major = try parseVersionPart(major_str);
    const minor = try parseVersionPart(minor_str);
    return Version.init(major, minor);
}

test "parse pyc version from filename" {
    const v311 = try parsePycVersion("test.3.11.pyc");
    try testing.expectEqual(@as(u8, 3), v311.major);
    try testing.expectEqual(@as(u8, 11), v311.minor);

    const v27 = try parsePycVersion("foo.2.7.pyc");
    try testing.expectEqual(@as(u8, 2), v27.major);
    try testing.expectEqual(@as(u8, 7), v27.minor);

    const v314 = try parsePycVersion("swap.3.14.pyc");
    try testing.expectEqual(@as(u8, 3), v314.major);
    try testing.expectEqual(@as(u8, 14), v314.minor);

    try testing.expectError(error.InvalidFilename, parsePycVersion("nope.pyc"));
}

fn decompilePycFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var module: pyc.Module = undefined;
    module.init(a);
    defer module.deinit();
    try module.loadFromFile(path);
    const version = module.version();
    const code = module.code orelse return error.InvalidPyc;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    try decompile.decompileToSource(a, code, version, out.writer(allocator));
    return out.toOwnedSlice(allocator);
}

test "pycdc test_global 2.5" {
    const allocator = testing.allocator;
    const output = try decompilePycFile(allocator, "refs/pycdc/tests/compiled/test_global.2.5.pyc");
    defer allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "global") != null);
}

test "pycdc swap 3.11" {
    const allocator = testing.allocator;
    const output = try decompilePycFile(allocator, "refs/pycdc/tests/compiled/swap.3.11.pyc");
    defer allocator.free(output);

    try testing.expect(output.len > 0);
}

test "pycdc test_loops2 2.2" {
    const allocator = testing.allocator;
    const output = try decompilePycFile(allocator, "refs/pycdc/tests/compiled/test_loops2.2.2.pyc");
    defer allocator.free(output);

    try testing.expect(output.len > 0);
}

test "pycdc test_listComprehensions 2.7" {
    const allocator = testing.allocator;
    const output = try decompilePycFile(allocator, "refs/pycdc/tests/compiled/test_listComprehensions.2.7.pyc");
    defer allocator.free(output);

    try testing.expect(output.len > 0);
}
