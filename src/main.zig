const std = @import("std");
const fs = std.fs;
const pyc = @import("pyc.zig");
const cfg_mod = @import("cfg.zig");
const ctrl = @import("ctrl.zig");
const decoder = @import("decoder.zig");
const codegen = @import("codegen.zig");
const decompile = @import("decompile.zig");
const test_harness = @import("test_harness.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up stdout/stderr with buffers
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = fs.File.stderr().writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // Parse command line
    var mode: enum { disasm, decompile, cfgdump, test_suite, golden } = .decompile;
    var filename: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--disasm")) {
            mode = .disasm;
        } else if (std.mem.eql(u8, arg, "--cfg")) {
            mode = .cfgdump;
        } else if (std.mem.eql(u8, arg, "--test")) {
            mode = .test_suite;
        } else if (std.mem.eql(u8, arg, "--golden")) {
            mode = .golden;
        } else if (arg[0] != '-') {
            filename = arg;
        }
    }

    // Test suite mode
    if (mode == .test_suite) {
        const test_dir = filename orelse "refs/pycdc/tests/compiled";
        const stats = try test_harness.runAllTests(allocator, test_dir, stdout);
        try stdout.flush();
        if (stats.failed > 0) std.process.exit(1);
        return;
    }

    // Golden file comparison mode
    if (mode == .golden) {
        const stats = try test_harness.runAllGoldenTests(
            allocator,
            "refs/pycdc/tests/compiled",
            "refs/pycdc/tests/input",
            stdout,
        );
        try stdout.flush();
        if (stats.mismatched > 0 or stats.errors > 0) std.process.exit(1);
        return;
    }

    if (filename == null) {
        try stderr.print("Usage: {s} [-d|--disasm|--cfg|--test|--golden] <file.pyc>\n", .{args[0]});
        try stderr.print("  -d, --disasm  Disassemble only\n", .{});
        try stderr.print("  --cfg         Dump CFG analysis\n", .{});
        try stderr.print("  --test        Run test suite (decompile check)\n", .{});
        try stderr.print("  --golden      Compare with golden .py files\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var module = pyc.Module.init(allocator);
    defer module.deinit();

    module.loadFromFile(filename.?) catch |err| {
        try stderr.print("Error loading {s}: {}\n", .{ filename.?, err });
        try stderr.flush();
        std.process.exit(1);
    };

    const version = decoder.Version.init(@intCast(module.major_ver), @intCast(module.minor_ver));

    switch (mode) {
        .disasm => {
            try stdout.print("# Python {d}.{d}\n", .{ module.major_ver, module.minor_ver });
            try stdout.print("# Disassembled by pez\n\n", .{});
            try module.disassemble(stdout);
        },
        .cfgdump => {
            try stdout.print("# CFG Analysis for Python {d}.{d}\n\n", .{ module.major_ver, module.minor_ver });
            if (module.code) |code| {
                try dumpCodeCFG(allocator, code, version, stdout, 0);
            }
        },
        .decompile => {
            try stdout.print("# Python {d}.{d}\n", .{ module.major_ver, module.minor_ver });
            try stdout.print("# Decompiled by pez\n\n", .{});
            if (module.code) |code| {
                try decompile.decompileToSource(allocator, code, version, stdout);
            }
        },
        .test_suite, .golden => unreachable, // Handled earlier
    }
    try stdout.flush();
}

fn dumpCodeCFG(allocator: std.mem.Allocator, code: *const pyc.Code, version: decoder.Version, writer: anytype, indent: u32) !void {
    // Print indent
    var i: u32 = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("  ");
    }

    try writer.print("Code object: {s}\n", .{codegen.extractFunctionName(code)});

    // Build CFG
    if (code.code.len > 0) {
        var cfg = try cfg_mod.buildCFG(allocator, code.code, version);
        defer cfg.deinit();

        // Print CFG summary
        i = 0;
        while (i < indent) : (i += 1) {
            try writer.writeAll("  ");
        }
        try writer.print("  Blocks: {d}, Entry: {d}\n", .{ cfg.blocks.len, cfg.entry });

        // Analyze control flow patterns
        var analyzer = try ctrl.Analyzer.init(allocator, &cfg);
        defer analyzer.deinit();

        for (cfg.blocks, 0..) |block, block_idx| {
            const bid: u32 = @intCast(block_idx);
            const pattern = try analyzer.detectPattern(bid);

            i = 0;
            while (i < indent) : (i += 1) {
                try writer.writeAll("  ");
            }

            switch (pattern) {
                .if_stmt => |p| {
                    try writer.print("  Block {d}: IF (then={d}, else={?d}, merge={?d})\n", .{ bid, p.then_block, p.else_block, p.merge_block });
                },
                .while_loop => |p| {
                    try writer.print("  Block {d}: WHILE (body={d}, exit={d})\n", .{ bid, p.body_block, p.exit_block });
                },
                .for_loop => |p| {
                    try writer.print("  Block {d}: FOR (body={d}, exit={d})\n", .{ bid, p.body_block, p.exit_block });
                },
                .try_stmt => |p| {
                    try writer.print("  Block {d}: TRY (handlers={d})\n", .{ bid, p.handlers.len });
                },
                .with_stmt => |p| {
                    try writer.print("  Block {d}: WITH (body={d}, cleanup={d})\n", .{ bid, p.body_block, p.cleanup_block });
                },
                else => {
                    if (block.is_loop_header) {
                        try writer.print("  Block {d}: LOOP_HEADER\n", .{bid});
                    } else if (block.is_exception_handler) {
                        try writer.print("  Block {d}: EXCEPTION_HANDLER\n", .{bid});
                    }
                },
            }
        }
    }

    try writer.writeByte('\n');

    // Recurse into nested code objects
    for (code.consts) |c| {
        if (c == .code) {
            const nested = c.code;
            try dumpCodeCFG(allocator, nested, version, writer, indent + 1);
        }
    }
}
