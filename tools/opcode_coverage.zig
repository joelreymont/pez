//! Opcode coverage analysis tool.
//!
//! Generates a matrix showing which opcodes are implemented across Python versions.

const std = @import("std");
const opcodes = @import("opcodes");

const Version = opcodes.Version;
const Opcode = opcodes.Opcode;

const versions = [_]Version{
    Version.init(1, 5),
    Version.init(2, 3),
    Version.init(2, 6),
    Version.init(2, 7),
    Version.init(3, 0),
    Version.init(3, 1),
    Version.init(3, 5),
    Version.init(3, 6),
    Version.init(3, 7),
    Version.init(3, 8),
    Version.init(3, 9),
    Version.init(3, 10),
    Version.init(3, 11),
    Version.init(3, 12),
    Version.init(3, 13),
    Version.init(3, 14),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&stdout_buf);
    const w = &file_writer.interface;

    // Header
    try w.writeAll("Opcode Coverage Matrix\n");
    try w.writeAll("======================\n\n");

    // Version headers
    try w.writeAll("Opcode                           ");
    for (versions) |v| {
        try w.print("{d}.{d:0>2}  ", .{ v.major, v.minor });
    }
    try w.writeAll("\n");
    try w.writeAll("---------------------------------");
    for (versions) |_| {
        try w.writeAll("-----");
    }
    try w.writeAll("\n");

    // Collect all opcodes that appear in any version
    var opcode_set = std.AutoHashMap(Opcode, void).init(ally);
    defer opcode_set.deinit();

    for (versions) |v| {
        const table = opcodes.getOpcodeTable(v);
        for (table) |maybe_op| {
            if (maybe_op) |op| {
                try opcode_set.put(op, {});
            }
        }
    }

    // Sort opcodes by name for consistent output
    var opcode_list: std.ArrayList(Opcode) = .{};
    defer opcode_list.deinit(ally);

    var it = opcode_set.keyIterator();
    while (it.next()) |op| {
        try opcode_list.append(ally, op.*);
    }

    std.mem.sort(Opcode, opcode_list.items, {}, struct {
        fn lessThan(_: void, a: Opcode, b: Opcode) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.lessThan);

    // Print each opcode's availability
    for (opcode_list.items) |op| {
        const name = @tagName(op);
        try w.print("{s:<33}", .{name});

        for (versions) |v| {
            const present = opcodeExistsInVersion(v, op);
            try w.writeAll(if (present) " ✓   " else " -   ");
        }
        try w.writeAll("\n");
    }

    // Summary statistics
    try w.writeAll("\n");
    try w.writeAll("Summary\n");
    try w.writeAll("-------\n");
    for (versions) |v| {
        const total = countOpcodesInVersion(v);
        try w.print("Python {d}.{d}: {d} opcodes\n", .{ v.major, v.minor, total });
    }
    try w.flush();
}

fn opcodeExistsInVersion(ver: Version, op: Opcode) bool {
    const table = opcodes.getOpcodeTable(ver);
    for (table) |maybe_op| {
        if (maybe_op) |found| {
            if (found == op) return true;
        }
    }
    return false;
}

fn countOpcodesInVersion(ver: Version) usize {
    const table = opcodes.getOpcodeTable(ver);
    var count: usize = 0;
    for (table) |maybe_op| {
        if (maybe_op) |_| count += 1;
    }
    return count;
}
