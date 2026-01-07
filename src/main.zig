const std = @import("std");
const fs = std.fs;
const pyc = @import("pyc.zig");

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

    if (args.len < 2) {
        try stderr.print("Usage: {s} <file.pyc>\n", .{args[0]});
        try stderr.flush();
        std.process.exit(1);
    }

    const filename = args[1];

    var module = pyc.Module.init(allocator);
    defer module.deinit();

    module.loadFromFile(filename) catch |err| {
        try stderr.print("Error loading {s}: {}\n", .{ filename, err });
        try stderr.flush();
        std.process.exit(1);
    };

    try stdout.print("# Python {d}.{d}\n", .{ module.major_ver, module.minor_ver });
    try stdout.print("# Decompiled by pez\n\n", .{});

    // TODO: Decompile and output Python source
    try module.disassemble(stdout);
    try stdout.flush();
}
