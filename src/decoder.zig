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
            .JUMP_ABSOLUTE,
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_IF_NONE,
            .POP_JUMP_IF_NOT_NONE,
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_FORWARD_IF_FALSE,
            .POP_JUMP_FORWARD_IF_NONE,
            .POP_JUMP_FORWARD_IF_NOT_NONE,
            .POP_JUMP_BACKWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_FALSE,
            .POP_JUMP_BACKWARD_IF_NONE,
            .POP_JUMP_BACKWARD_IF_NOT_NONE,
            .JUMP_IF_TRUE_OR_POP,
            .JUMP_IF_FALSE_OR_POP,
            .JUMP_IF_TRUE, // Python 3.0
            .JUMP_IF_FALSE, // Python 3.0
            .JUMP_IF_NOT_EXC_MATCH,
            .FOR_ITER,
            .FOR_LOOP,
            .SEND,
            .CONTINUE_LOOP,
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
            .JUMP_ABSOLUTE,
            .CONTINUE_LOOP,
            .BREAK_LOOP,
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
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_FORWARD_IF_FALSE,
            .POP_JUMP_FORWARD_IF_NONE,
            .POP_JUMP_FORWARD_IF_NOT_NONE,
            .POP_JUMP_BACKWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_FALSE,
            .POP_JUMP_BACKWARD_IF_NONE,
            .POP_JUMP_BACKWARD_IF_NOT_NONE,
            .JUMP_IF_TRUE_OR_POP,
            .JUMP_IF_FALSE_OR_POP,
            .JUMP_IF_TRUE, // Python 3.0
            .JUMP_IF_FALSE, // Python 3.0
            .JUMP_IF_NOT_EXC_MATCH,
            .FOR_ITER,
            .FOR_LOOP,
            .SEND,
            .CONTINUE_LOOP,
            => true,
            else => false,
        };
    }

    /// Check if this instruction terminates a basic block.
    pub fn isBlockTerminator(self: Instruction) bool {
        // Terminators that don't fall through
        return switch (self.opcode) {
            .RETURN_VALUE,
            .RETURN_CONST,
            .RAISE_VARARGS,
            .RERAISE,
            .JUMP_FORWARD,
            .JUMP_BACKWARD,
            .JUMP_BACKWARD_NO_INTERRUPT,
            .JUMP_ABSOLUTE,
            .CONTINUE_LOOP,
            .BREAK_LOOP,
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

        // In Python 3.10+, jump args are instruction offsets (word units).
        // In Python <= 3.9, jump args are byte offsets.
        const multiplier: u32 = if (ver.gte(3, 10)) 2 else 1;

        return switch (self.opcode) {
            .JUMP_FORWARD => next_offset + self.arg * multiplier,
            .JUMP_BACKWARD, .JUMP_BACKWARD_NO_INTERRUPT => next_offset -| (self.arg *| multiplier),
            .JUMP_ABSOLUTE, .CONTINUE_LOOP => self.arg * multiplier,
            .FOR_ITER, .FOR_LOOP, .SEND => next_offset + self.arg * multiplier, // Jump on exhaustion/end
            .POP_JUMP_IF_TRUE,
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_IF_NONE,
            .POP_JUMP_IF_NOT_NONE,
            => blk: {
                // Python 3.11+: relative offsets from next instruction
                // Python <= 3.10: absolute offsets in bytes
                if (ver.gte(3, 11)) {
                    break :blk next_offset + self.arg * multiplier;
                }
                break :blk self.arg * multiplier;
            },
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_FORWARD_IF_FALSE,
            .POP_JUMP_FORWARD_IF_NONE,
            .POP_JUMP_FORWARD_IF_NOT_NONE,
            => next_offset + self.arg * multiplier,
            .POP_JUMP_BACKWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_FALSE,
            .POP_JUMP_BACKWARD_IF_NONE,
            .POP_JUMP_BACKWARD_IF_NOT_NONE,
            => next_offset -| (self.arg *| multiplier),
            .JUMP_IF_TRUE_OR_POP,
            .JUMP_IF_FALSE_OR_POP,
            .JUMP_IF_NOT_EXC_MATCH,
            => self.arg * multiplier,
            .JUMP_IF_TRUE, // Python 3.0 - relative forward offset
            .JUMP_IF_FALSE, // Python 3.0 - relative forward offset
            => next_offset + self.arg * multiplier,
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
        const ext_shift: u5 = if (word_based) 8 else 16;

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
            self.extended_arg = (self.extended_arg | arg) << ext_shift;
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

pub const BytecodeDiag = struct {
    pos: u32,
    note: ?[]const u8,
};

pub fn validateBytecode(bytecode: []const u8, version: Version, diag: *BytecodeDiag) error{InvalidBytecode}!void {
    diag.* = .{ .pos = 0, .note = null };
    var pos: usize = 0;
    var extended_arg: u32 = 0;
    const word_based = version.gte(3, 6);
    const ext_shift: u5 = if (word_based) 8 else 16;

    while (pos < bytecode.len) {
        const start = pos;
        const op_byte = bytecode[pos];
        pos += 1;

        const opcode = opcodes.byteToOpcode(version, op_byte) orelse {
            diag.* = .{ .pos = @intCast(start), .note = "invalid opcode" };
            return error.InvalidBytecode;
        };

        var arg: u32 = 0;
        if (word_based) {
            if (pos >= bytecode.len) {
                diag.* = .{ .pos = @intCast(start), .note = "truncated instruction" };
                return error.InvalidBytecode;
            }
            arg = bytecode[pos];
            pos += 1;
        } else if (opcode.hasArg(version)) {
            if (pos + 1 >= bytecode.len) {
                diag.* = .{ .pos = @intCast(start), .note = "truncated instruction" };
                return error.InvalidBytecode;
            }
            arg = @as(u32, bytecode[pos]) | (@as(u32, bytecode[pos + 1]) << 8);
            pos += 2;
        }

        if (opcode == .EXTENDED_ARG) {
            extended_arg = (extended_arg | arg) << ext_shift;
            continue;
        }

        if (extended_arg != 0) {
            arg |= extended_arg;
            extended_arg = 0;
        }

        const cache_count = opcodes.cacheEntries(opcode, version);
        const cache_bytes = @as(usize, cache_count) * 2;
        if (pos + cache_bytes > bytecode.len) {
            diag.* = .{ .pos = @intCast(start), .note = "truncated cache" };
            return error.InvalidBytecode;
        }
        pos += cache_bytes;

        const base_size: u16 = if (word_based) 2 else if (opcode.hasArg(version)) 3 else 1;
        const inst = Instruction{
            .opcode = opcode,
            .arg = arg,
            .offset = @intCast(start),
            .size = base_size + @as(u16, cache_count) * 2,
            .cache_entries = cache_count,
        };

        if (inst.jumpTarget(version)) |target| {
            if (target >= bytecode.len) {
                diag.* = .{ .pos = @intCast(start), .note = "jump target out of range" };
                return error.InvalidBytecode;
            }
        }
    }

    if (extended_arg != 0) {
        diag.* = .{ .pos = @intCast(bytecode.len), .note = "dangling EXTENDED_ARG" };
        return error.InvalidBytecode;
    }
}

fn opcodeByte(version: Version, op: Opcode) u8 {
    const table = opcodes.getOpcodeTable(version);
    for (table, 0..) |entry, idx| {
        if (entry == op) return @intCast(idx);
    }
    @panic("opcode not in table");
}

test "pre-3.6 EXTENDED_ARG uses 16-bit chunks" {
    const testing = std.testing;
    const version = Version.init(2, 7);

    const bytecode = [_]u8{
        opcodeByte(version, .EXTENDED_ARG),
        0x01,
        0x00,
        opcodeByte(version, .LOAD_CONST),
        0x45,
        0x23,
    };

    var iter = InstructionIterator.init(&bytecode, version);
    const inst = iter.next().?;
    try testing.expectEqual(Opcode.LOAD_CONST, inst.opcode);
    try testing.expectEqual(@as(u32, 0x12345), inst.arg);
    try testing.expectEqual(@as(u32, 3), inst.offset);
    try testing.expectEqual(@as(u16, 3), inst.size);
    try testing.expect(iter.next() == null);
}

test "pre-3.6 opcode without arg is size 1" {
    const testing = std.testing;
    const version = Version.init(2, 7);
    const bytecode = [_]u8{opcodeByte(version, .NOP)};

    var iter = InstructionIterator.init(&bytecode, version);
    const inst = iter.next().?;
    try testing.expectEqual(Opcode.NOP, inst.opcode);
    try testing.expectEqual(@as(u32, 0), inst.arg);
    try testing.expectEqual(@as(u32, 0), inst.offset);
    try testing.expectEqual(@as(u16, 1), inst.size);
    try testing.expect(iter.next() == null);
}

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

test "jump target pop jump 3.11" {
    const testing = std.testing;
    const v311 = Version.init(3, 11);

    const forward = Instruction{
        .opcode = .POP_JUMP_FORWARD_IF_FALSE,
        .arg = 2,
        .offset = 10,
        .size = 2,
        .cache_entries = 0,
    };
    try testing.expectEqual(@as(u32, 16), forward.jumpTarget(v311).?);

    const backward = Instruction{
        .opcode = .POP_JUMP_BACKWARD_IF_FALSE,
        .arg = 2,
        .offset = 10,
        .size = 2,
        .cache_entries = 0,
    };
    try testing.expectEqual(@as(u32, 8), backward.jumpTarget(v311).?);
}

test "jump target pop jump 3.10 wordcode" {
    const testing = std.testing;
    const v310 = Version.init(3, 10);

    const inst = Instruction{
        .opcode = .POP_JUMP_IF_FALSE,
        .arg = 10,
        .offset = 10,
        .size = 2,
        .cache_entries = 0,
    };
    try testing.expectEqual(@as(u32, 20), inst.jumpTarget(v310).?);
}

test "jump target pop jump 3.12 relative" {
    const testing = std.testing;
    const v312 = Version.init(3, 12);

    const inst = Instruction{
        .opcode = .POP_JUMP_IF_FALSE,
        .arg = 11,
        .offset = 34,
        .size = 2,
        .cache_entries = 0,
    };
    try testing.expectEqual(@as(u32, 58), inst.jumpTarget(v312).?);
}

// ============================================================================
// Line Number Table Parsing
// ============================================================================

/// A single entry in the line table mapping bytecode offset range to line number.
pub const LineEntry = struct {
    start_offset: u32,
    end_offset: u32,
    line: ?u32, // null = no line number for this range
};

/// Parsed line table for efficient bytecode offset to line number lookup.
pub const LineTable = struct {
    entries: []const LineEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LineTable) void {
        self.allocator.free(self.entries);
    }

    /// Look up the line number for a given bytecode offset.
    /// Returns null if the offset has no associated line or is out of range.
    pub fn getLine(self: LineTable, offset: u32) ?u32 {
        // Binary search for the entry containing this offset
        var lo: usize = 0;
        var hi: usize = self.entries.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = self.entries[mid];

            if (offset < entry.start_offset) {
                hi = mid;
            } else if (offset >= entry.end_offset) {
                lo = mid + 1;
            } else {
                return entry.line;
            }
        }
        return null;
    }
};

/// Parse a line number table from a code object.
/// Handles lnotab (pre-3.10), linetable (3.10), and locations table (3.11+).
pub fn parseLineTable(
    linetable: []const u8,
    firstlineno: u32,
    version: Version,
    allocator: std.mem.Allocator,
) !LineTable {
    var entries: std.ArrayList(LineEntry) = .{};
    errdefer entries.deinit(allocator);

    if (version.gte(3, 11)) {
        try parseLocationsTable(linetable, firstlineno, &entries, allocator);
    } else if (version.gte(3, 10)) {
        try parseLineTable310(linetable, firstlineno, &entries, allocator);
    } else {
        try parseLnotab(linetable, firstlineno, version, &entries, allocator);
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Parse pre-3.10 lnotab format.
fn parseLnotab(
    lnotab: []const u8,
    firstlineno: u32,
    version: Version,
    entries: *std.ArrayList(LineEntry),
    allocator: std.mem.Allocator,
) !void {
    if (lnotab.len == 0) return;
    if (lnotab.len % 2 != 0) return error.InvalidLineTable; // Invalid: must be pairs

    var addr: u32 = 0;
    var line: i32 = @intCast(firstlineno);
    var prev_addr: u32 = 0;
    var prev_line: i32 = line;

    var i: usize = 0;
    while (i + 1 < lnotab.len) : (i += 2) {
        const addr_incr = lnotab[i];
        const line_incr_byte = lnotab[i + 1];

        // Python 3.8+: line increment is signed
        const line_incr: i32 = if (version.gte(3, 8) and line_incr_byte >= 128)
            @as(i32, line_incr_byte) - 256
        else
            line_incr_byte;

        addr += addr_incr;

        // Only emit entry when line actually changes
        if (line_incr != 0) {
            if (addr > prev_addr) {
                try entries.append(allocator, .{
                    .start_offset = prev_addr,
                    .end_offset = addr,
                    .line = if (prev_line >= 0) @intCast(prev_line) else null,
                });
            }
            prev_addr = addr;
            prev_line = line + line_incr;
        }

        line += line_incr;
    }

    // Emit final entry (covers rest of bytecode)
    if (prev_line >= 0) {
        try entries.append(allocator, .{
            .start_offset = prev_addr,
            .end_offset = std.math.maxInt(u32),
            .line = @intCast(prev_line),
        });
    }
}

/// Parse Python 3.10 linetable format (signed line deltas).
fn parseLineTable310(
    linetable: []const u8,
    firstlineno: u32,
    entries: *std.ArrayList(LineEntry),
    allocator: std.mem.Allocator,
) !void {
    if (linetable.len == 0) return;
    if (linetable.len % 2 != 0) return error.InvalidLineTable;

    var addr: u32 = 0;
    var line: i32 = @intCast(firstlineno);

    var i: usize = 0;
    while (i + 1 < linetable.len) : (i += 2) {
        const start_delta = linetable[i];
        const line_delta_byte: i8 = @bitCast(linetable[i + 1]);

        const end_addr = addr + start_delta;

        // -128 means no line number for this range
        const entry_line: ?u32 = if (line_delta_byte == -128)
            null
        else blk: {
            line += line_delta_byte;
            break :blk if (line >= 0) @intCast(line) else null;
        };

        if (start_delta > 0) {
            try entries.append(allocator, .{
                .start_offset = addr,
                .end_offset = end_addr,
                .line = entry_line,
            });
        }

        addr = end_addr;
    }
}

/// Parse Python 3.11+ locations table format (includes column info, though we ignore columns).
fn parseLocationsTable(
    linetable: []const u8,
    firstlineno: u32,
    entries: *std.ArrayList(LineEntry),
    allocator: std.mem.Allocator,
) !void {
    if (linetable.len == 0) return;

    var pos: usize = 0;
    var addr: u32 = 0;
    var line: i32 = @intCast(firstlineno);

    while (pos < linetable.len) {
        const header = linetable[pos];
        pos += 1;

        // Header byte must have bit 7 set
        if ((header & 0x80) == 0) return error.InvalidLineTable;

        const code: u4 = @intCast((header >> 3) & 0x0F);
        const length: u32 = @as(u32, header & 0x07) + 1; // Length in code units

        // Each code unit is 2 bytes (word-aligned bytecode)
        const byte_length = length * 2;
        const end_addr = addr + byte_length;

        var entry_line: ?u32 = null;

        switch (code) {
            0...9 => {
                // Short form: 2 bytes total, same line
                if (pos >= linetable.len) return error.InvalidLineTable;
                pos += 1; // Skip column byte
                entry_line = if (line >= 0) @intCast(line) else null;
            },
            10, 11, 12 => {
                // One line form: line_delta = code - 10
                const line_delta: i32 = @as(i32, code) - 10;
                line += line_delta;
                // Skip start_col and end_col bytes
                if (pos + 1 >= linetable.len) return error.InvalidLineTable;
                pos += 2;
                entry_line = if (line >= 0) @intCast(line) else null;
            },
            13 => {
                // No column info: line_delta as svarint
                const varint_result = try readVarint(linetable, pos);
                pos = varint_result.new_pos;
                const line_delta = decodeSvarint(varint_result.value);
                line += line_delta;
                entry_line = if (line >= 0) @intCast(line) else null;
            },
            14 => {
                // Long form: all fields as varints
                const line_delta_result = try readVarint(linetable, pos);
                pos = line_delta_result.new_pos;
                const line_delta = decodeSvarint(line_delta_result.value);
                line += line_delta;

                // Skip end_line_delta, start_col, end_col
                const end_line_result = try readVarint(linetable, pos);
                pos = end_line_result.new_pos;
                const start_col_result = try readVarint(linetable, pos);
                pos = start_col_result.new_pos;
                const end_col_result = try readVarint(linetable, pos);
                pos = end_col_result.new_pos;

                entry_line = if (line >= 0) @intCast(line) else null;
            },
            15 => {
                // No location: entry_line stays null
            },
        }

        if (byte_length > 0) {
            try entries.append(allocator, .{
                .start_offset = addr,
                .end_offset = end_addr,
                .line = entry_line,
            });
        }

        addr = end_addr;
    }
}

/// Read a variable-length unsigned integer (6-bit chunks, LSB first).
fn readVarint(data: []const u8, start_pos: usize) !struct { value: u32, new_pos: usize } {
    var result: u32 = 0;
    var shift: u5 = 0;
    var pos = start_pos;

    while (pos < data.len) {
        const byte = data[pos];
        pos += 1;

        result |= @as(u32, byte & 0x3F) << shift;

        // Bit 6 not set = last chunk
        if ((byte & 0x40) == 0) {
            return .{ .value = result, .new_pos = pos };
        }

        shift +|= 6;
        if (shift > 30) return error.InvalidLineTable; // Overflow protection
    }

    return error.InvalidLineTable;
}

/// Decode a zigzag-encoded signed integer.
fn decodeSvarint(val: u32) i32 {
    if ((val & 1) != 0) {
        return -@as(i32, @intCast(val >> 1));
    }
    return @intCast(val >> 1);
}

test "lnotab parsing basic" {
    const testing = std.testing;

    // Simple lnotab: offset 0-6 = line 1, offset 6-50 = line 2
    // Encoded as: (6, 1), (44, 1)
    const lnotab = [_]u8{ 6, 1, 44, 1 };
    const v37 = Version.init(3, 7);

    var table = try parseLineTable(&lnotab, 1, v37, testing.allocator);
    defer table.deinit();

    try testing.expectEqual(@as(?u32, 1), table.getLine(0));
    try testing.expectEqual(@as(?u32, 1), table.getLine(5));
    try testing.expectEqual(@as(?u32, 2), table.getLine(6));
    try testing.expectEqual(@as(?u32, 2), table.getLine(49));
    try testing.expectEqual(@as(?u32, 3), table.getLine(50));
}

test "lnotab parsing rejects odd length" {
    const testing = std.testing;
    const lnotab = [_]u8{ 6, 1, 44 };
    const v37 = Version.init(3, 7);

    try testing.expectError(error.InvalidLineTable, parseLineTable(&lnotab, 1, v37, testing.allocator));
}

test "linetable310 rejects odd length" {
    const testing = std.testing;
    const linetable = [_]u8{1};
    const v310 = Version.init(3, 10);

    try testing.expectError(error.InvalidLineTable, parseLineTable(&linetable, 1, v310, testing.allocator));
}

test "lnotab parsing with signed deltas" {
    const testing = std.testing;

    // Python 3.8+: line can go backwards
    // Line 10, then back to line 8
    // (10, 0) to advance addr, then (10, -2) for line 8
    // -2 as u8 = 254
    const lnotab = [_]u8{ 10, 0, 10, 254 };
    const v38 = Version.init(3, 8);

    var table = try parseLineTable(&lnotab, 10, v38, testing.allocator);
    defer table.deinit();

    try testing.expectEqual(@as(?u32, 10), table.getLine(0));
    try testing.expectEqual(@as(?u32, 8), table.getLine(20));
}

test "locations table rejects invalid header" {
    const testing = std.testing;
    const linetable = [_]u8{0x00};
    const v311 = Version.init(3, 11);

    try testing.expectError(error.InvalidLineTable, parseLineTable(&linetable, 1, v311, testing.allocator));
}

test "locations table rejects truncated varint" {
    const testing = std.testing;
    const linetable = [_]u8{ 0xE8, 0x40 };
    const v311 = Version.init(3, 11);

    try testing.expectError(error.InvalidLineTable, parseLineTable(&linetable, 1, v311, testing.allocator));
}

test "locations table parsing code 15" {
    const testing = std.testing;

    // Code 15 (no location) for 2 code units (4 bytes)
    // Header: 0x80 | (15 << 3) | (2-1) = 0x80 | 0x78 | 0x01 = 0xF9
    const locations = [_]u8{0xF9};
    const v311 = Version.init(3, 11);

    var table = try parseLineTable(&locations, 1, v311, testing.allocator);
    defer table.deinit();

    try testing.expectEqual(@as(usize, 1), table.entries.len);
    try testing.expectEqual(@as(?u32, null), table.getLine(0));
}
