//! Python bytecode instruction decoder.
//!
//! Provides types and functions for iterating over bytecode instructions,
//! handling version-specific encoding and EXTENDED_ARG.

const std = @import("std");
const opcodes = @import("opcodes.zig");

pub const Version = opcodes.Version;
pub const Opcode = opcodes.Opcode;

/// A decoded Python bytecode instruction.
pub const Instruction = struct {
    /// The canonical opcode (version-independent).
    opcode: Opcode,
    /// The instruction argument (after EXTENDED_ARG accumulation).
    /// For opcodes without arguments, this is 0.
    arg: u32,
    /// Byte offset of this instruction in the bytecode.
    offset: u32,
    /// Size of this instruction in bytes (including cache entries).
    size: u16,
    /// Number of inline cache entries that follow this instruction.
    cache_entries: u8,

    /// Check if this instruction is a jump.
    pub fn isJump(self: Instruction) bool {
        return switch (self.opcode) {
            .JUMP_FORWARD,
            .JUMP_BACKWARD,
            .JUMP_BACKWARD_NO_INTERRUPT,
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_IF_NONE,
            .POP_JUMP_IF_NOT_NONE,
            .FOR_ITER,
            .SEND,
            => true,
            else => false,
        };
    }

    /// Check if this instruction unconditionally transfers control.
    pub fn isUnconditionalJump(self: Instruction) bool {
        return switch (self.opcode) {
            .JUMP_FORWARD,
            .JUMP_BACKWARD,
            .JUMP_BACKWARD_NO_INTERRUPT,
            => true,
            else => false,
        };
    }

    /// Check if this instruction is a conditional branch.
    pub fn isConditionalJump(self: Instruction) bool {
        return switch (self.opcode) {
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_IF_NONE,
            .POP_JUMP_IF_NOT_NONE,
            .FOR_ITER,
            .SEND,
            => true,
            else => false,
        };
    }

    /// Check if this instruction terminates a basic block.
    pub fn isBlockTerminator(self: Instruction) bool {
        return switch (self.opcode) {
            .RETURN_VALUE,
            .RETURN_CONST,
            .RAISE_VARARGS,
            .RERAISE,
            .JUMP_FORWARD,
            .JUMP_BACKWARD,
            .JUMP_BACKWARD_NO_INTERRUPT,
            => true,
            else => false,
        };
    }

    /// Get the target offset of a jump instruction.
    /// For forward jumps, arg is added to the next instruction offset.
    /// For backward jumps, arg is subtracted from the next instruction offset.
    /// Returns null for non-jump instructions.
    pub fn jumpTarget(self: Instruction, ver: Version) ?u32 {
        if (!self.isJump()) return null;

        // Next instruction offset
        const next_offset = self.offset + self.size;

        // In Python 3.10+, jump args are instruction offsets (word units), not byte offsets
        // In Python < 3.10, jump args are byte offsets
        const multiplier: u32 = if (ver.gte(3, 10)) 2 else 1;

        return switch (self.opcode) {
            .JUMP_FORWARD => next_offset + self.arg * multiplier,
            .JUMP_BACKWARD, .JUMP_BACKWARD_NO_INTERRUPT => next_offset - self.arg * multiplier,
            .FOR_ITER, .SEND => next_offset + self.arg * multiplier, // Jump on exhaustion/end
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_IF_NONE,
            .POP_JUMP_IF_NOT_NONE,
            => blk: {
                // In 3.11, these were split into forward/backward variants
                // In 3.12+, they use absolute offsets (word units)
                if (ver.gte(3, 12)) {
                    break :blk self.arg * multiplier;
                }
                // For 3.11 forward variants (byte 114, 115, 128, 129), arg is forward offset
                // This is a simplification - in practice we'd check the raw byte
                break :blk next_offset + self.arg * multiplier;
            },
            else => null,
        };
    }
};

/// Iterator over bytecode instructions.
pub const InstructionIterator = struct {
    bytecode: []const u8,
    version: Version,
    pos: usize,
    extended_arg: u32,

    pub fn init(bytecode: []const u8, version: Version) InstructionIterator {
        return .{
            .bytecode = bytecode,
            .version = version,
            .pos = 0,
            .extended_arg = 0,
        };
    }

    /// Get the next instruction, or null if at end of bytecode.
    pub fn next(self: *InstructionIterator) ?Instruction {
        if (self.pos >= self.bytecode.len) return null;

        const start_offset = self.pos;
        const op_byte = self.bytecode[self.pos];
        self.pos += 1;

        const opcode = opcodes.byteToOpcode(self.version, op_byte) orelse .INVALID;

        // In Python 3.6+, all instructions are 2 bytes (word-based)
        const word_based = self.version.gte(3, 6);

        var arg: u32 = 0;
        if (word_based) {
            // All instructions have an arg byte in 3.6+
            if (self.pos < self.bytecode.len) {
                arg = self.bytecode[self.pos];
                self.pos += 1;
            }
        } else {
            // Pre-3.6: variable-size instructions
            if (opcode.hasArg(self.version) and self.pos + 1 < self.bytecode.len) {
                arg = @as(u32, self.bytecode[self.pos]) |
                    (@as(u32, self.bytecode[self.pos + 1]) << 8);
                self.pos += 2;
            }
        }

        // Handle EXTENDED_ARG
        if (opcode == .EXTENDED_ARG) {
            self.extended_arg = (self.extended_arg | arg) << 8;
            // Recursively get the next instruction with accumulated extended_arg
            return self.next();
        }

        // Apply accumulated extended_arg
        if (self.extended_arg != 0) {
            arg |= self.extended_arg;
            self.extended_arg = 0;
        }

        // Calculate cache entries and total size
        const cache_count = opcodes.cacheEntries(opcode, self.version);
        const cache_bytes = @as(usize, cache_count) * 2;
        self.pos += cache_bytes; // Skip cache entries

        const base_size: u16 = if (word_based) 2 else if (opcode.hasArg(self.version)) 3 else 1;

        return Instruction{
            .opcode = opcode,
            .arg = arg,
            .offset = @intCast(start_offset),
            .size = base_size + @as(u16, cache_count) * 2,
            .cache_entries = cache_count,
        };
    }

    /// Reset the iterator to the beginning.
    pub fn reset(self: *InstructionIterator) void {
        self.pos = 0;
        self.extended_arg = 0;
    }

    /// Collect all instructions into a slice.
    pub fn collectAlloc(self: *InstructionIterator, allocator: std.mem.Allocator) ![]Instruction {
        self.reset();

        var instructions: std.ArrayList(Instruction) = .{};
        errdefer instructions.deinit(allocator);

        while (self.next()) |inst| {
            try instructions.append(allocator, inst);
        }

        return instructions.toOwnedSlice(allocator);
    }
};

test "instruction iterator basic" {
    const testing = std.testing;
    const v312 = Version.init(3, 12);

    // Simple bytecode: RESUME 0, LOAD_CONST 0, RETURN_VALUE
    // In 3.12: RESUME=151(byte), LOAD_CONST=100, RETURN_VALUE=83
    // But we need to use the actual byte values for 3.12
    // RESUME is at byte 151, LOAD_CONST at 100, RETURN_VALUE at 83
    const bytecode = [_]u8{
        151, 0, // RESUME 0
        100, 0, // LOAD_CONST 0
        83, 0, // RETURN_VALUE (no arg but still 2 bytes in 3.6+)
    };

    var iter = InstructionIterator.init(&bytecode, v312);

    const inst1 = iter.next().?;
    try testing.expectEqual(Opcode.RESUME, inst1.opcode);
    try testing.expectEqual(@as(u32, 0), inst1.arg);
    try testing.expectEqual(@as(u32, 0), inst1.offset);

    const inst2 = iter.next().?;
    try testing.expectEqual(Opcode.LOAD_CONST, inst2.opcode);
    try testing.expectEqual(@as(u32, 0), inst2.arg);
    try testing.expectEqual(@as(u32, 2), inst2.offset);

    const inst3 = iter.next().?;
    try testing.expectEqual(Opcode.RETURN_VALUE, inst3.opcode);
    try testing.expectEqual(@as(u32, 4), inst3.offset);

    try testing.expect(iter.next() == null);
}

test "instruction iterator with cache entries" {
    const testing = std.testing;
    const v312 = Version.init(3, 12);

    // LOAD_GLOBAL has 4 cache entries in 3.12
    // LOAD_GLOBAL is byte 116 in 3.12
    const bytecode = [_]u8{
        116, 0, // LOAD_GLOBAL 0
        0, 0, // cache entry 1
        0, 0, // cache entry 2
        0, 0, // cache entry 3
        0, 0, // cache entry 4
        83, 0, // RETURN_VALUE
    };

    var iter = InstructionIterator.init(&bytecode, v312);

    const inst1 = iter.next().?;
    try testing.expectEqual(Opcode.LOAD_GLOBAL, inst1.opcode);
    try testing.expectEqual(@as(u8, 4), inst1.cache_entries);
    try testing.expectEqual(@as(u16, 2 + 4 * 2), inst1.size);

    const inst2 = iter.next().?;
    try testing.expectEqual(Opcode.RETURN_VALUE, inst2.opcode);
    try testing.expectEqual(@as(u32, 10), inst2.offset);

    try testing.expect(iter.next() == null);
}

test "extended arg" {
    const testing = std.testing;
    const v312 = Version.init(3, 12);

    // EXTENDED_ARG is byte 144 in 3.12, LOAD_CONST is 100
    // EXTENDED_ARG(1) followed by LOAD_CONST(0) should give arg = 256
    const bytecode = [_]u8{
        144, 1, // EXTENDED_ARG 1
        100, 0, // LOAD_CONST 0 -> actual arg = (1 << 8) | 0 = 256
    };

    var iter = InstructionIterator.init(&bytecode, v312);

    const inst = iter.next().?;
    try testing.expectEqual(Opcode.LOAD_CONST, inst.opcode);
    try testing.expectEqual(@as(u32, 256), inst.arg);
    // Offset is where LOAD_CONST starts, not where EXTENDED_ARG started
    // EXTENDED_ARG is consumed transparently
    try testing.expectEqual(@as(u32, 2), inst.offset);

    try testing.expect(iter.next() == null);
}
