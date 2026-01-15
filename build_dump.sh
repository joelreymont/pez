#!/bin/bash
cat > /tmp/dump.zig << 'ZIGEOF'
const std = @import("std");
const pyc = @import("pyc");
const decoder = @import("decoder");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    
    if (args.len < 2) return error.NoFile;
    
    const file = try std.fs.cwd().openFile(args[1], .{});
    defer file.close();
    
    const data = try file.readToEndAlloc(a, 1024 * 1024);
    defer a.free(data);
    
    const res = try pyc.parseFile(a, data, "test");
    defer res.code.deinit();
    
    std.debug.print("Version: {}.{}\n", .{res.version.major, res.version.minor});
    
    var iter = decoder.InstructionIterator.init(res.code.code, res.version);
    while (iter.next()) |inst| {
        if (inst.offset >= 55 and inst.offset <= 75) {
            std.debug.print("{:3} {s:20} {}\n", .{inst.offset, inst.opcode.name(), inst.arg});
        }
    }
}
ZIGEOF

zig build-exe /tmp/dump.zig \
  --mod pyc::src/pyc.zig \
  --mod decoder::src/decoder.zig \
  --mod opcodes::src/opcodes.zig \
  --deps pyc,decoder \
  -femit-bin=/tmp/dump 2>&1

/tmp/dump refs/pycdc/tests/compiled/test_divide_future.2.2.pyc 2>&1
