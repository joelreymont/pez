const std = @import("std");
const fs = std.fs;
const pyc = @import("pyc.zig");
const cfg_mod = @import("cfg.zig");
const ctrl = @import("ctrl.zig");
const dom_mod = @import("dom.zig");
const decoder = @import("decoder.zig");
const codegen = @import("codegen.zig");
const decompile = @import("decompile.zig");
const test_harness = @import("test_harness.zig");
const version = @import("util/version.zig");
const debug_dump = @import("debug_dump.zig");

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
    var mode: enum { disasm, decompile, cfgdump, dump, test_suite, golden } = .decompile;
    var filename: ?[]const u8 = null;
    var dump_sections: ?[]const u8 = null;
    var dump_json: ?[]const u8 = null;
    var focus: ?[]const u8 = null;
    var trace_loop_guards = false;
    var trace_sim_block: ?u32 = null;
    var trace_decisions = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--disasm")) {
            mode = .disasm;
        } else if (std.mem.eql(u8, arg, "--cfg")) {
            mode = .cfgdump;
        } else if (std.mem.startsWith(u8, arg, "--dump=")) {
            mode = .dump;
            dump_sections = arg["--dump=".len..];
        } else if (std.mem.eql(u8, arg, "--dump")) {
            mode = .dump;
        } else if (std.mem.startsWith(u8, arg, "--dump-json=")) {
            mode = .dump;
            dump_json = arg["--dump-json=".len..];
        } else if (std.mem.eql(u8, arg, "--test")) {
            mode = .test_suite;
        } else if (std.mem.eql(u8, arg, "--golden")) {
            mode = .golden;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            try stdout.print("pez {s}\n", .{version.full});
            try stdout.flush();
            return;
        } else if (std.mem.startsWith(u8, arg, "--focus=")) {
            focus = arg["--focus=".len..];
        } else if (std.mem.eql(u8, arg, "--trace-loop-guards")) {
            trace_loop_guards = true;
        } else if (std.mem.eql(u8, arg, "--trace-decisions")) {
            trace_decisions = true;
        } else if (std.mem.startsWith(u8, arg, "--trace-sim=")) {
            const raw = arg["--trace-sim=".len..];
            trace_sim_block = std.fmt.parseInt(u32, raw, 10) catch {
                try stderr.print("Invalid --trace-sim value: {s}\n", .{raw});
                try stderr.flush();
                std.process.exit(1);
            };
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
        try stderr.print("Usage: {s} [-d|--disasm|--cfg|--dump|--test|--golden] [--focus=PATH] [--trace-loop-guards] [--trace-decisions] [--trace-sim=BLOCK] <file.pyc>\n", .{args[0]});
        try stderr.print("  -d, --disasm  Disassemble only\n", .{});
        try stderr.print("  --cfg         Dump CFG analysis\n", .{});
        try stderr.print("  --dump[=list] Dump JSON (bytecode,cfg,dom,loops,patterns,passes)\n", .{});
        try stderr.print("  --dump-json=PATH  Write dump JSON to PATH\n", .{});
        try stderr.print("  --focus=PATH  Decompile only a code path\n", .{});
        try stderr.print("  --trace-loop-guards  JSONL loop-guard trace to stderr\n", .{});
        try stderr.print("  --trace-decisions  JSONL decision trace to stderr\n", .{});
        try stderr.print("  --trace-sim=BLOCK  JSONL sim trace for block id to stderr\n", .{});
        try stderr.print("  --test        Run test suite (decompile check)\n", .{});
        try stderr.print("  --golden      Compare with golden .py files\n", .{});
        try stderr.print("  -V, --version Show version\n", .{});
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

    const py_ver = decoder.Version.init(@intCast(module.major_ver), @intCast(module.minor_ver));

    switch (mode) {
        .disasm => {
            try stdout.print("# Python {d}.{d}\n", .{ module.major_ver, module.minor_ver });
            try stdout.print("# Disassembled by pez {s}\n\n", .{version.full});
            try module.disassemble(stdout);
        },
        .cfgdump => {
            try stdout.print("# CFG Analysis for Python {d}.{d}\n\n", .{ module.major_ver, module.minor_ver });
            if (module.code) |code| {
                try dumpCodeCFG(allocator, code, py_ver, stdout, 0);
            }
        },
        .decompile => {
            if (module.code) |code| {
                const trace_file: ?std.fs.File = if (trace_loop_guards or trace_sim_block != null or trace_decisions)
                    std.fs.File.stderr()
                else
                    null;
                const opts = decompile.DecompileOptions{
                    .focus = focus,
                    .trace_loop_guards = trace_loop_guards,
                    .trace_sim_block = trace_sim_block,
                    .trace_decisions = trace_decisions,
                    .trace_file = trace_file,
                };
                try decompile.decompileToSourceWithOptions(allocator, code, py_ver, stdout, std.fs.File.stderr(), opts);
            }
        },
        .dump => {
            const sections = try debug_dump.parseSections(dump_sections);
            if (module.code) |code| {
                if (dump_json) |path| {
                    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                    defer file.close();
                    var buf: [8192]u8 = undefined;
                    var writer = file.writer(&buf);
                    const file_out = &writer.interface;
                    try debug_dump.dumpModule(allocator, code, py_ver, sections, file_out);
                    try file_out.flush();
                } else {
                    try debug_dump.dumpModule(allocator, code, py_ver, sections, stdout);
                }
            }
        },
        .test_suite, .golden => unreachable, // Handled earlier
    }
    try stdout.flush();
}

fn dumpCodeCFG(allocator: std.mem.Allocator, code: *const pyc.Code, py_ver: decoder.Version, writer: anytype, indent: u32) !void {
    // Print indent
    var i: u32 = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("  ");
    }

    try writer.print("Code object: {s}\n", .{codegen.extractFunctionName(code)});

    // Build CFG
    if (code.code.len > 0) {
        var cfg = try cfg_mod.buildCFGWithExceptions(allocator, code.code, code.exceptiontable, py_ver);
        defer cfg.deinit();

        // Print CFG summary
        i = 0;
        while (i < indent) : (i += 1) {
            try writer.writeAll("  ");
        }
        try writer.print("  Blocks: {d}, Entry: {d}\n", .{ cfg.blocks.len, cfg.entry });

        var dom = try dom_mod.DomTree.init(allocator, &cfg);
        defer dom.deinit();

        // Analyze control flow patterns
        var analyzer = try ctrl.Analyzer.init(allocator, &cfg, &dom);
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
                .match_stmt => |p| {
                    defer p.deinit(allocator);
                    try writer.print("  Block {d}: MATCH (cases={d}, exit={?d})\n", .{ bid, p.case_blocks.len, p.exit_block });
                },
                else => {
                    if (block.is_loop_header) {
                        try writer.print("  Block {d}: LOOP_HEADER\n", .{bid});
                    } else if (block.is_exception_handler) {
                        try writer.print("  Block {d}: EXCEPTION_HANDLER\n", .{bid});
                    }
                },
            }

            // Dump instructions
            i = 0;
            while (i < indent + 1) : (i += 1) {
                try writer.writeAll("  ");
            }
            try writer.print("  offset {d}-{d}, {d} instructions, successors: ", .{ block.start_offset, block.end_offset, block.instructions.len });
            for (block.successors, 0..) |edge, ei| {
                if (ei > 0) try writer.writeAll(", ");
                try writer.print("{d}({s})", .{ edge.target, @tagName(edge.edge_type) });
            }
            try writer.writeAll("\n");
            for (block.instructions) |inst| {
                i = 0;
                while (i < indent + 1) : (i += 1) {
                    try writer.writeAll("  ");
                }
                try writer.print("    {d}: {s} {d}\n", .{ inst.offset, @tagName(inst.opcode), inst.arg });
            }
        }
    }

    try writer.writeByte('\n');

    // Recurse into nested code objects
    for (code.consts) |c| {
        if (c == .code) {
            const nested = c.code;
            try dumpCodeCFG(allocator, nested, py_ver, writer, indent + 1);
        }
    }
}
