const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip symbols (default: false)") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Run only tests containing this substring");

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.strip = strip;

    const exe = b.addExecutable(.{
        .name = "pez",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run pez decompiler");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_test_filters = if (test_filter) |filter| &.{filter} else &.{};

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.strip = strip;

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = unit_test_filters,
    });

    // ohsnap snapshot testing
    if (b.lazyDependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
    })) |ohsnap_dep| {
        unit_tests.root_module.addImport("ohsnap", ohsnap_dep.module("ohsnap"));
    }

    // zcheck property testing
    if (b.lazyDependency("zcheck", .{
        .target = target,
        .optimize = optimize,
    })) |zcheck_dep| {
        unit_tests.root_module.addImport("zcheck", zcheck_dep.module("zcheck"));
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Debug under lldb
    const lldb = b.addSystemCommand(&.{ "lldb", "--" });
    lldb.addArtifactArg(unit_tests);
    const lldb_step = b.step("debug", "Run tests under lldb");
    lldb_step.dependOn(&lldb.step);
}
