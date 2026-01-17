//! Integration tests using pycdc test suite.

const std = @import("std");
const testing = std.testing;
const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const opcodes = @import("opcodes.zig");

const Version = opcodes.Version;

fn parsePycVersion(filename: []const u8) !Version {
    var idx = std.mem.lastIndexOf(u8, filename, ".") orelse return error.InvalidFilename;
    if (idx == 0) return error.InvalidFilename;
    idx -= 1;

    var end = idx;
    while (end > 0 and (std.ascii.isDigit(filename[end]) or filename[end] == '.')) : (end -= 1) {}
    end += 1;

    const ver_str = filename[end .. idx + 1];
    var it = std.mem.splitScalar(u8, ver_str, '.');
    const major_str = it.next() orelse return error.InvalidFilename;
    const minor_str = it.next() orelse return error.InvalidFilename;

    const major = if (std.fmt.parseInt(u8, major_str, 10)) |value| value else |_| return error.InvalidFilename;
    const minor = if (std.fmt.parseInt(u8, minor_str, 10)) |value| value else |_| return error.InvalidFilename;

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
    const version = try parsePycVersion(path);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var module = try pyc.Module.fromFile(allocator, file.reader());
    defer module.deinit();

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    try decompile.decompileToSource(allocator, module.code, version, out.writer(allocator));
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
