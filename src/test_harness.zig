//! Test harness for comparing decompiled output with expected Python source.
//!
//! Provides functions to:
//! - Run all .pyc tests from refs/pycdc/tests/compiled/
//! - Compare output with expected .py source from refs/pycdc/tests/input/
//! - Report pass/fail status and diffs

const std = @import("std");
const pyc = @import("pyc.zig");
const decompile = @import("decompile.zig");
const opcodes = @import("opcodes.zig");

const Allocator = std.mem.Allocator;
const Version = opcodes.Version;

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
    const name = try allocator.dupe(u8, std.fs.path.basename(pyc_path));
    errdefer allocator.free(name);

    // Load .pyc
    const pyc_file = try std.fs.cwd().openFile(pyc_path, .{});
    defer pyc_file.close();

    var module = try pyc.Module.unmarshal(allocator, pyc_file.reader(allocator));
    defer module.deinit();

    // Decompile
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const version = Version{ .major = @intCast(module.magic >> 8), .minor = @intCast(module.magic & 0xFF) };
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
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);
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

    return result.toOwnedSlice(allocator);
}

/// Parse Python version from filename like "test.3.11.pyc".
fn parseVersion(filename: []const u8) ?Version {
    const idx = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return null;
    if (idx == 0) return null;

    // Find version part before .pyc
    const end = idx;
    var start = end;
    var dots: u8 = 0;
    while (start > 0) : (start -= 1) {
        const c = filename[start - 1];
        if (c == '.') {
            dots += 1;
            if (dots == 2) break;
        } else if (!std.ascii.isDigit(c)) {
            break;
        }
    }

    if (dots < 1) return null;

    const ver_str = filename[start..end];
    var it = std.mem.splitScalar(u8, ver_str, '.');
    const major_str = it.next() orelse return null;
    const minor_str = it.next() orelse return null;

    const major = std.fmt.parseInt(u8, major_str, 10) catch return null;
    const minor = std.fmt.parseInt(u8, minor_str, 10) catch return null;

    return Version.init(major, minor);
}

/// Statistics from running tests.
pub const TestStats = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    errors: usize = 0,
};

/// Check if version is supported by pez.
fn isVersionSupported(version: Version) bool {
    if (version.major == 2) return true;
    if (version.major == 3 and version.minor >= 6) return true;
    return false;
}

/// Extract base test name from pyc filename (remove version suffix).
/// "test_foo.3.11.pyc" -> "test_foo"
fn getBaseName(filename: []const u8) []const u8 {
    // Remove .pyc
    const no_ext = if (std.mem.endsWith(u8, filename, ".pyc"))
        filename[0 .. filename.len - 4]
    else
        filename;

    // Remove version suffix (e.g., ".3.11")
    var end = no_ext.len;
    var dots: u8 = 0;
    while (end > 0) : (end -= 1) {
        const c = no_ext[end - 1];
        if (c == '.') {
            dots += 1;
            if (dots == 2) {
                return no_ext[0 .. end - 1];
            }
        } else if (!std.ascii.isDigit(c)) {
            break;
        }
    }
    return no_ext;
}

/// Normalize source code for comparison (strip trailing whitespace, normalize line endings).
fn normalizeSource(allocator: Allocator, source: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.append(allocator, '\n');
        first = false;
        // Trim trailing whitespace
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        try result.appendSlice(allocator, trimmed);
    }

    return result.toOwnedSlice(allocator);
}

/// Run a single .pyc file test, return true if decompilation succeeds.
pub fn runSingleTest(allocator: Allocator, pyc_path: []const u8, writer: anytype) !bool {
    const basename = std.fs.path.basename(pyc_path);

    const version = parseVersion(basename) orelse {
        try writer.print("SKIP {s} (no version)\n", .{basename});
        return false;
    };

    if (!isVersionSupported(version)) {
        try writer.print("SKIP {s} (unsupported {d}.{d})\n", .{ basename, version.major, version.minor });
        return false;
    }

    // Load .pyc
    var module = pyc.Module.init(allocator);
    defer module.deinit();

    module.loadFromFile(pyc_path) catch |err| {
        try writer.print("ERR  {s}: load failed: {s}\n", .{ basename, @errorName(err) });
        return false;
    };

    const code = module.code orelse {
        try writer.print("ERR  {s}: no code object\n", .{basename});
        return false;
    };

    // Decompile
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    decompile.decompileToSource(allocator, code, version, output.writer(allocator)) catch |err| {
        try writer.print("FAIL {s}: {s}\n", .{ basename, @errorName(err) });
        return false;
    };

    try writer.print("PASS {s} ({d} bytes)\n", .{ basename, output.items.len });
    return true;
}

/// Compare result with golden file and return match status.
pub const CompareResult = enum { match, mismatch, no_golden, decompile_error };

/// Run test with golden file comparison.
pub fn runGoldenTest(
    allocator: Allocator,
    pyc_path: []const u8,
    input_dir: []const u8,
    writer: anytype,
) !CompareResult {
    const basename = std.fs.path.basename(pyc_path);
    const base_name = getBaseName(basename);

    const version = parseVersion(basename) orelse {
        try writer.print("SKIP {s} (no version)\n", .{basename});
        return .no_golden;
    };

    if (!isVersionSupported(version)) {
        try writer.print("SKIP {s} (unsupported {d}.{d})\n", .{ basename, version.major, version.minor });
        return .no_golden;
    }

    // Load expected .py file
    var golden_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const golden_path = std.fmt.bufPrint(&golden_path_buf, "{s}/{s}.py", .{ input_dir, base_name }) catch {
        try writer.print("SKIP {s} (path too long)\n", .{basename});
        return .no_golden;
    };

    const golden_file = std.fs.cwd().openFile(golden_path, .{}) catch {
        try writer.print("SKIP {s} (no golden: {s})\n", .{ basename, golden_path });
        return .no_golden;
    };
    defer golden_file.close();

    const golden_content = golden_file.readToEndAlloc(allocator, 1024 * 1024) catch {
        try writer.print("ERR  {s}: cannot read golden\n", .{basename});
        return .no_golden;
    };
    defer allocator.free(golden_content);

    // Load and decompile .pyc
    var module = pyc.Module.init(allocator);
    defer module.deinit();

    module.loadFromFile(pyc_path) catch |err| {
        try writer.print("ERR  {s}: load failed: {s}\n", .{ basename, @errorName(err) });
        return .decompile_error;
    };

    const code = module.code orelse {
        try writer.print("ERR  {s}: no code object\n", .{basename});
        return .decompile_error;
    };

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    decompile.decompileToSource(allocator, code, version, output.writer(allocator)) catch |err| {
        try writer.print("FAIL {s}: {s}\n", .{ basename, @errorName(err) });
        return .decompile_error;
    };

    // Normalize and compare
    const norm_golden = try normalizeSource(allocator, golden_content);
    defer allocator.free(norm_golden);

    const norm_output = try normalizeSource(allocator, output.items);
    defer allocator.free(norm_output);

    if (std.mem.eql(u8, norm_golden, norm_output)) {
        try writer.print("MATCH {s}\n", .{basename});
        return .match;
    } else {
        try writer.print("DIFF  {s}\n", .{basename});
        // Print first few lines of diff
        const diff = try computeDiff(allocator, norm_golden, norm_output);
        defer allocator.free(diff);
        if (diff.len > 0) {
            // Limit diff output
            const max_diff = @min(diff.len, 500);
            try writer.print("{s}", .{diff[0..max_diff]});
            if (diff.len > max_diff) try writer.print("... ({d} more bytes)\n", .{diff.len - max_diff});
        }
        return .mismatch;
    }
}

/// Run all .pyc tests in the given directory.
pub fn runAllTests(allocator: Allocator, test_dir: []const u8, writer: anytype) !TestStats {
    var stats = TestStats{};

    var dir = std.fs.cwd().openDir(test_dir, .{ .iterate = true }) catch |err| {
        try writer.print("Cannot open {s}: {s}\n", .{ test_dir, @errorName(err) });
        return stats;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pyc")) continue;

        stats.total += 1;

        // Build full path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ test_dir, entry.name }) catch continue;

        if (runSingleTest(allocator, full_path, writer) catch false) {
            stats.passed += 1;
        } else {
            if (parseVersion(entry.name) == null) {
                stats.skipped += 1;
            } else {
                stats.failed += 1;
            }
        }
    }

    try writer.print("\n=== Results ===\n", .{});
    try writer.print("Total:   {d}\n", .{stats.total});
    try writer.print("Passed:  {d}\n", .{stats.passed});
    try writer.print("Failed:  {d}\n", .{stats.failed});
    try writer.print("Skipped: {d}\n", .{stats.skipped});

    return stats;
}

/// Golden test statistics.
pub const GoldenStats = struct {
    total: usize = 0,
    matched: usize = 0,
    mismatched: usize = 0,
    no_golden: usize = 0,
    errors: usize = 0,
};

/// Run all golden file comparisons.
pub fn runAllGoldenTests(
    allocator: Allocator,
    compiled_dir: []const u8,
    input_dir: []const u8,
    writer: anytype,
) !GoldenStats {
    var stats = GoldenStats{};

    var dir = std.fs.cwd().openDir(compiled_dir, .{ .iterate = true }) catch |err| {
        try writer.print("Cannot open {s}: {s}\n", .{ compiled_dir, @errorName(err) });
        return stats;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pyc")) continue;

        stats.total += 1;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ compiled_dir, entry.name }) catch continue;

        const result = runGoldenTest(allocator, full_path, input_dir, writer) catch .decompile_error;
        switch (result) {
            .match => stats.matched += 1,
            .mismatch => stats.mismatched += 1,
            .no_golden => stats.no_golden += 1,
            .decompile_error => stats.errors += 1,
        }
    }

    try writer.print("\n=== Golden Test Results ===\n", .{});
    try writer.print("Total:      {d}\n", .{stats.total});
    try writer.print("Matched:    {d}\n", .{stats.matched});
    try writer.print("Mismatched: {d}\n", .{stats.mismatched});
    try writer.print("No golden:  {d}\n", .{stats.no_golden});
    try writer.print("Errors:     {d}\n", .{stats.errors});

    return stats;
}

test "parse version from filename" {
    const testing = std.testing;
    try testing.expectEqual(Version.init(3, 11), parseVersion("test.3.11.pyc").?);
    try testing.expectEqual(Version.init(2, 7), parseVersion("foo.2.7.pyc").?);
    try testing.expect(parseVersion("nope.pyc") == null);
}

test "get base name from pyc filename" {
    const testing = std.testing;
    try testing.expectEqualStrings("test_foo", getBaseName("test_foo.3.11.pyc"));
    try testing.expectEqualStrings("swap", getBaseName("swap.2.7.pyc"));
    try testing.expectEqualStrings("if_elif_else", getBaseName("if_elif_else.3.9.pyc"));
}

test "run pycdc test suite" {
    const allocator = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const stats = try runAllTests(allocator, "refs/pycdc/tests/compiled", stream.writer());
    _ = stats;
    // Just ensure it runs without crashing
}
