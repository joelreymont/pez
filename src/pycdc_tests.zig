//! Integration tests using pycdc test suite.

const std = @import("std");
const testing = std.testing;
const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const opcodes = @import("opcodes.zig");

const Version = opcodes.Version;

fn parsePycVersion(filename: []const u8) ?Version {
    var idx = std.mem.lastIndexOf(u8, filename, ".") orelse return null;
    if (idx == 0) return null;
    idx -= 1;

    var end = idx;
    while (end > 0 and (std.ascii.isDigit(filename[end]) or filename[end] == '.')) : (end -= 1) {}
    end += 1;

    const ver_str = filename[end .. idx + 1];
    var it = std.mem.splitScalar(u8, ver_str, '.');
    const major_str = it.next() orelse return null;
    const minor_str = it.next() orelse return null;

    const major = std.fmt.parseInt(u8, major_str, 10) catch return null;
    const minor = std.fmt.parseInt(u8, minor_str, 10) catch return null;

    return Version.init(major, minor);
}

test "parse pyc version from filename" {
    try testing.expectEqual(Version.init(3, 11), parsePycVersion("test.3.11.pyc").?);
    try testing.expectEqual(Version.init(2, 7), parsePycVersion("foo.2.7.pyc").?);
    try testing.expectEqual(Version.init(3, 14), parsePycVersion("swap.3.14.pyc").?);
    try testing.expect(parsePycVersion("nope.pyc") == null);
}

fn decompilePycFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const version = parsePycVersion(path) orelse return error.InvalidFilename;

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
