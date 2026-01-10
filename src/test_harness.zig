//! Test harness for comparing decompiled output with expected Python source.

const std = @import("std");
const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const decoder = @import("decoder.zig");

const Allocator = std.mem.Allocator;

/// Test result for a single .pyc file.
pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    expected: []const u8,
    actual: []const u8,
    diff: ?[]const u8,

    pub fn deinit(self: *TestResult, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.expected);
        allocator.free(self.actual);
        if (self.diff) |d| allocator.free(d);
    }
};

/// Load .pyc, decompile, compare with expected .py source.
pub fn testPycFile(
    allocator: Allocator,
    pyc_path: []const u8,
    expected_py: []const u8,
) !TestResult {
    var name = try allocator.dupe(u8, std.fs.path.basename(pyc_path));
    errdefer allocator.free(name);

    // Load .pyc
    const pyc_file = try std.fs.cwd().openFile(pyc_path, .{});
    defer pyc_file.close();

    var module = try pyc.Module.unmarshal(allocator, pyc_file.reader(allocator));
    defer module.deinit();

    // Decompile
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const version = decoder.Version{ .major = @intCast(module.magic >> 8), .minor = @intCast(module.magic & 0xFF) };
    try decompile.decompileToSource(allocator, &module.code, version, output.writer(allocator));

    const actual = try output.toOwnedSlice();
    errdefer allocator.free(actual);

    const expected = try allocator.dupe(u8, expected_py);
    errdefer allocator.free(expected);

    // Compare
    const passed = std.mem.eql(u8, expected, actual);
    const diff = if (!passed) try computeDiff(allocator, expected, actual) else null;

    return .{
        .name = name,
        .passed = passed,
        .expected = expected,
        .actual = actual,
        .diff = diff,
    };
}

fn computeDiff(allocator: Allocator, expected: []const u8, actual: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    const w = result.writer(allocator);

    var exp_lines = std.mem.splitScalar(u8, expected, '\n');
    var act_lines = std.mem.splitScalar(u8, actual, '\n');

    var line_no: usize = 1;
    while (true) {
        const exp_line = exp_lines.next();
        const act_line = act_lines.next();

        if (exp_line == null and act_line == null) break;

        const exp = exp_line orelse "";
        const act = act_line orelse "";

        if (!std.mem.eql(u8, exp, act)) {
            try w.print("Line {d}:\n", .{line_no});
            try w.print("  Expected: {s}\n", .{exp});
            try w.print("  Actual:   {s}\n", .{act});
        }
        line_no += 1;
    }

    return result.toOwnedSlice();
}
