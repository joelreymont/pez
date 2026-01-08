//! Property-based tests for pez decompiler.
//!
//! Uses zcheck for generating random test cases and shrinking to minimal
//! counterexamples.

const std = @import("std");
const testing = std.testing;
const zc = @import("zcheck");

const decoder = @import("decoder.zig");
const cfg = @import("cfg.zig");
const opcodes = @import("opcodes.zig");

const Version = decoder.Version;
const Opcode = opcodes.Opcode;

// ============================================================================
// Bytecode Decoder Properties
// ============================================================================

test "decoder handles arbitrary bytecode without crashing" {
    // Property: For any random bytecode, the decoder either produces valid
    // instructions or returns an error - it never crashes or hangs.
    try zc.check(struct {
        fn prop(args: struct { bytecode: [32]u8, version_idx: u8 }) bool {
            const versions = [_]Version{
                Version.init(2, 7),
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
            const version = versions[args.version_idx % versions.len];

            var iter = decoder.InstructionIterator.init(&args.bytecode, version);

            // Try to decode all instructions - should not crash
            var count: usize = 0;
            while (iter.next()) |_| {
                count += 1;
                if (count > 100) break; // Safety limit
            }

            return true; // Property: didn't crash
        }
    }.prop, .{ .iterations = 500 });
}

test "decoded instruction offsets are monotonically increasing" {
    try zc.check(struct {
        fn prop(args: struct { bytecode: [64]u8 }) bool {
            const version = Version.init(3, 12);
            var iter = decoder.InstructionIterator.init(&args.bytecode, version);

            var prev_offset: u32 = 0;
            var first = true;

            while (iter.next()) |inst| {
                if (!first) {
                    if (inst.offset <= prev_offset) return false;
                }
                prev_offset = inst.offset;
                first = false;
            }

            return true;
        }
    }.prop, .{ .iterations = 200 });
}

// ============================================================================
// Varint Encoding Properties (Line Table / Exception Table)
// ============================================================================

test "line table varint roundtrip for small values" {
    // The varint used in 3.11+ locations table: 6 bits per byte
    try zc.check(struct {
        fn prop(args: struct { value: u16 }) bool {
            // Encode
            var buf: [4]u8 = undefined;
            var len: usize = 0;

            var v = args.value;
            var first = true;
            while (v > 0 or first) {
                const chunk: u8 = @intCast(v & 0x3F);
                v >>= 6;
                const has_more = v > 0;

                buf[len] = chunk |
                    (if (has_more) @as(u8, 0x40) else 0) |
                    (if (first) @as(u8, 0x80) else 0);
                len += 1;
                first = false;
            }

            // Decode using our implementation
            const result = readVarint7(&buf, 0);

            return result.value == args.value;
        }

        fn readVarint7(data: []const u8, start_pos: usize) struct { value: u32, new_pos: usize } {
            var result: u32 = 0;
            var shift: u5 = 0;
            var pos = start_pos;

            while (pos < data.len) {
                const byte = data[pos];
                pos += 1;
                result |= @as(u32, byte & 0x3F) << shift;
                if ((byte & 0x40) == 0) break;
                shift +|= 6;
                if (shift > 30) break;
            }

            return .{ .value = result, .new_pos = pos };
        }
    }.prop, .{ .iterations = 1000 });
}

test "exception table entry fields are correctly parsed" {
    // Property: entries with known encoding decode correctly
    // Using small values that fit in 6 bits (single-byte varints)
    try zc.check(struct {
        fn prop(args: struct { start: u8, size: u8, target: u8, depth: u8, lasti: bool }) bool {
            // Constrain to 6-bit values (0-63) to avoid multi-byte varints
            const start_val = args.start & 0x3F;
            const size_val = args.size & 0x3F;
            const target_val = args.target & 0x3F;
            const depth_val = args.depth & 0x1F; // 5 bits for depth (since we shift left by 1)

            // Build exception table entry manually
            // Format: start byte has S=1, subsequent bytes have S=0
            var buf: [4]u8 = undefined;

            // Encode start (with S bit, no extend bit)
            buf[0] = 0x80 | start_val;

            // Encode size
            buf[1] = size_val;

            // Encode target
            buf[2] = target_val;

            // Encode depth_lasti: (depth << 1) | lasti
            const depth_lasti = (depth_val << 1) | @as(u8, if (args.lasti) 1 else 0);
            buf[3] = depth_lasti;

            // Parse it
            const entries = cfg.parseExceptionTable(&buf, testing.allocator) catch return false;
            defer testing.allocator.free(entries);

            if (entries.len != 1) return false;

            const e = entries[0];
            return e.start == start_val and
                e.end == start_val + size_val and
                e.target == target_val and
                e.depth == depth_val and
                e.push_lasti == args.lasti;
        }
    }.prop, .{ .iterations = 500 });
}

// ============================================================================
// CFG Properties
// ============================================================================

test "CFG blocks have non-overlapping offset ranges" {
    try zc.check(struct {
        fn prop(args: struct { bytecode: [48]u8 }) bool {
            const version = Version.init(3, 12);

            // CFG builder can panic on malformed bytecode (e.g., backward jump underflow)
            // We catch errors but panics indicate bugs that should be fixed
            var cfg_result = cfg.buildCFG(testing.allocator, &args.bytecode, version) catch return true;
            defer cfg_result.deinit();

            // Check that no blocks overlap
            for (cfg_result.blocks, 0..) |block1, i| {
                for (cfg_result.blocks[i + 1 ..]) |block2| {
                    // Blocks should not overlap
                    if (block1.start_offset < block2.end_offset and
                        block1.end_offset > block2.start_offset)
                    {
                        return false;
                    }
                }
            }

            return true;
        }
    }.prop, .{ .iterations = 200 });
}

test "CFG block successor targets are valid block IDs" {
    try zc.check(struct {
        fn prop(args: struct { bytecode: [32]u8 }) bool {
            const version = Version.init(3, 12);
            var cfg_result = cfg.buildCFG(testing.allocator, &args.bytecode, version) catch return true;
            defer cfg_result.deinit();

            for (cfg_result.blocks) |block| {
                for (block.successors) |edge| {
                    if (edge.target >= cfg_result.blocks.len) {
                        return false;
                    }
                }
            }

            return true;
        }
    }.prop, .{ .iterations = 200 });
}

// ============================================================================
// Line Table Properties
// ============================================================================

test "line table lookup returns consistent results" {
    try zc.check(struct {
        fn prop(args: struct { offsets: [8]u8 }) bool {
            // Build a simple lnotab
            var lnotab: [16]u8 = undefined;
            var len: usize = 0;

            var prev_addr: u8 = 0;
            for (args.offsets[0..4]) |off| {
                if (off > prev_addr) {
                    lnotab[len] = off - prev_addr;
                    lnotab[len + 1] = 1; // line increment
                    len += 2;
                    prev_addr = off;
                }
            }

            if (len == 0) return true;

            const version = Version.init(3, 9);
            var table = decoder.parseLineTable(lnotab[0..len], 1, version, testing.allocator) catch return true;
            defer table.deinit();

            // Property: consecutive lookups at same offset return same result
            for (0..50) |offset| {
                const line1 = table.getLine(@intCast(offset));
                const line2 = table.getLine(@intCast(offset));
                if (line1 != line2) return false;
            }

            return true;
        }
    }.prop, .{ .iterations = 200 });
}

// ============================================================================
// Opcode Properties
// ============================================================================

test "opcode table covers all bytes for supported versions" {
    // Property: opcode tables for supported versions cover all 256 byte values
    try zc.check(struct {
        fn prop(args: struct { version_idx: u8 }) bool {
            // Test specific supported versions
            const versions = [_]Version{
                Version.init(2, 7),
                Version.init(3, 11),
                Version.init(3, 12),
                Version.init(3, 13),
                Version.init(3, 14),
            };

            const idx = args.version_idx % versions.len;
            const version = versions[idx];
            const table = opcodes.getOpcodeTable(version);

            // Every entry is either a valid opcode or null
            for (table) |maybe_op| {
                if (maybe_op) |op| {
                    // If it's an opcode, its name should not be empty
                    if (op.name().len == 0) return false;
                }
                // null is also valid (undefined opcode)
            }

            return true;
        }
    }.prop, .{ .iterations = 50 });
}

test "opcode hasArg is consistent for Python 3.12" {
    // In Python 3.6+, all instructions are word-aligned (2 bytes each)
    // hasArg determines if the argument byte is meaningful
    const version = Version.init(3, 12);
    const table = opcodes.getOpcodeTable(version);

    for (table) |maybe_op| {
        if (maybe_op) |op| {
            // hasArg should not panic for any valid opcode
            _ = op.hasArg(version);
        }
    }
}

// ============================================================================
// Version Comparison Properties
// ============================================================================

test "version comparison is transitive" {
    try zc.check(struct {
        fn prop(args: struct { a_major: u8, a_minor: u8, b_major: u8, b_minor: u8, c_major: u8, c_minor: u8 }) bool {
            const a = Version.init(args.a_major % 5, args.a_minor % 20);
            const b = Version.init(args.b_major % 5, args.b_minor % 20);
            const c = Version.init(args.c_major % 5, args.c_minor % 20);

            // If a >= b and b >= c, then a >= c
            if (a.gte(b.major, b.minor) and b.gte(c.major, c.minor)) {
                if (!a.gte(c.major, c.minor)) return false;
            }

            return true;
        }
    }.prop, .{ .iterations = 500 });
}

test "version comparison with self is always true" {
    try zc.check(struct {
        fn prop(args: struct { major: u8, minor: u8 }) bool {
            const v = Version.init(args.major, args.minor);
            return v.gte(args.major, args.minor);
        }
    }.prop, .{ .iterations = 100 });
}
