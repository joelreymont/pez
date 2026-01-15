//! Python bytecode (.pyc) file parser.
//!
//! Handles .pyc files from Python 1.0 through 3.13+.
//! The .pyc format consists of:
//! - Magic number (4 bytes) - identifies Python version
//! - Header (variable size based on version)
//! - Marshalled code object
//!
//! See refs/pycdc for reference implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const opcodes = @import("opcodes.zig");

pub const Version = opcodes.Version;

/// Arbitrary precision integer for Python's TYPE_LONG.
/// Stores the magnitude as an array of 15-bit digits in little-endian order.
/// This matches Python's internal representation for marshal format.
pub const BigInt = struct {
    /// Array of 15-bit digits (stored in u16, only lower 15 bits used).
    /// Digits are in little-endian order (least significant first).
    digits: []const u16,
    /// True if the number is negative.
    negative: bool,

    pub const DIGIT_BITS: u5 = 15;
    pub const DIGIT_MASK: u16 = (1 << DIGIT_BITS) - 1; // 0x7FFF

    /// Create a BigInt from marshal format digits.
    pub fn init(allocator: Allocator, digit_count: usize, negative: bool, reader: anytype) !BigInt {
        if (digit_count == 0) {
            return .{ .digits = &.{}, .negative = false };
        }

        const digits = try allocator.alloc(u16, digit_count);
        errdefer allocator.free(digits);

        for (digits) |*d| {
            if (reader.pos + 2 > reader.data.len) return error.UnexpectedEndOfFile;
            const val = std.mem.readInt(u16, reader.data[reader.pos..][0..2], .little);
            reader.pos += 2;
            d.* = val & DIGIT_MASK;
        }

        // Normalize: remove trailing zero digits
        var len = digits.len;
        while (len > 0 and digits[len - 1] == 0) {
            len -= 1;
        }

        if (len == 0) {
            allocator.free(digits);
            return .{ .digits = &.{}, .negative = false };
        }

        if (len < digits.len) {
            // Shrink allocation
            const trimmed = allocator.realloc(digits, len) catch digits[0..len];
            return .{ .digits = trimmed, .negative = negative };
        }

        return .{ .digits = digits, .negative = negative };
    }

    /// Try to convert to i64. Returns null if the value doesn't fit.
    pub fn toI64(self: BigInt) ?i64 {
        if (self.digits.len == 0) return 0;

        // Maximum digits that could fit in i64: ceil(63 / 15) = 5
        if (self.digits.len > 5) return null;

        var result: u64 = 0;
        var shift: u6 = 0;
        for (self.digits) |digit| {
            const contribution = @as(u64, digit) << shift;
            // Check for overflow before adding
            if (shift >= 64) return null;
            result |= contribution;
            shift += DIGIT_BITS;
        }

        // Check if it fits in i64
        if (self.negative) {
            if (result > @as(u64, @intCast(std.math.maxInt(i64))) + 1) return null;
            if (result == @as(u64, @intCast(std.math.maxInt(i64))) + 1) return std.math.minInt(i64);
            return -@as(i64, @intCast(result));
        } else {
            if (result > @as(u64, @intCast(std.math.maxInt(i64)))) return null;
            return @intCast(result);
        }
    }

    /// Try to convert to i128. Returns null if the value doesn't fit.
    pub fn toI128(self: BigInt) ?i128 {
        if (self.digits.len == 0) return 0;

        // Maximum digits that could fit in i128: ceil(127 / 15) = 9
        if (self.digits.len > 9) return null;

        var result: u128 = 0;
        var shift: u7 = 0;
        for (self.digits) |digit| {
            if (shift >= 128) return null;
            result |= @as(u128, digit) << shift;
            shift += DIGIT_BITS;
        }

        // Check if it fits in i128
        if (self.negative) {
            if (result > @as(u128, @intCast(std.math.maxInt(i128))) + 1) return null;
            if (result == @as(u128, @intCast(std.math.maxInt(i128))) + 1) return std.math.minInt(i128);
            return -@as(i128, @intCast(result));
        } else {
            if (result > @as(u128, @intCast(std.math.maxInt(i128)))) return null;
            return @intCast(result);
        }
    }

    pub fn deinit(self: *BigInt, allocator: Allocator) void {
        if (self.digits.len > 0) allocator.free(self.digits);
        self.* = .{ .digits = &.{}, .negative = false };
    }

    pub fn clone(self: BigInt, allocator: Allocator) Allocator.Error!BigInt {
        if (self.digits.len == 0) return .{ .digits = &.{}, .negative = false };
        return .{
            .digits = try allocator.dupe(u16, self.digits),
            .negative = self.negative,
        };
    }

    pub fn format(
        self: BigInt,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        // Try to print as decimal if it fits in i128
        if (self.toI128()) |val| {
            try writer.print("{d}", .{val});
            return;
        }

        // For very large numbers, print as hex (like pycdc does)
        if (self.negative) try writer.writeByte('-');
        try writer.writeAll("0x");

        // Convert 15-bit digits to 32-bit for easier hex output
        var bits: std.ArrayList(u32) = .{};
        defer bits.deinit(std.heap.page_allocator);

        var shift: u5 = 0;
        var temp: u32 = 0;
        for (self.digits) |digit| {
            temp |= @as(u32, digit) << shift;
            shift += BigInt.DIGIT_BITS;
            if (shift >= 32) {
                bits.append(std.heap.page_allocator, temp) catch return;
                shift -= 32;
                temp = @as(u32, digit) >> (BigInt.DIGIT_BITS - shift);
            }
        }
        if (temp != 0 or bits.items.len == 0) {
            bits.append(std.heap.page_allocator, temp) catch return;
        }

        // Print from most significant to least
        var first = true;
        var i = bits.items.len;
        while (i > 0) {
            i -= 1;
            if (first) {
                try writer.print("{X}", .{bits.items[i]});
                first = false;
            } else {
                try writer.print("{X:0>8}", .{bits.items[i]});
            }
        }
    }
};

/// .pyc magic numbers identify Python versions.
/// Format: 0x0A0D???? where ???? varies by version.
pub const Magic = enum(u32) {
    // Python 1.x
    MAGIC_1_0 = 0x00999902,
    MAGIC_1_1 = 0x00999903, // Also covers 1.2
    MAGIC_1_3 = 0x0A0D2E89,
    MAGIC_1_4 = 0x0A0D1704,
    MAGIC_1_5 = 0x0A0D4E99,
    MAGIC_1_6 = 0x0A0DC4FC,

    // Python 2.x
    MAGIC_2_0 = 0x0A0DC687,
    MAGIC_2_1 = 0x0A0DEB2A,
    MAGIC_2_2 = 0x0A0DED2D,
    MAGIC_2_3 = 0x0A0DF23B,
    MAGIC_2_4 = 0x0A0DF26D,
    MAGIC_2_5 = 0x0A0DF2B3,
    MAGIC_2_6 = 0x0A0DF2D1,
    MAGIC_2_7 = 0x0A0DF303,

    // Python 3.x
    MAGIC_3_0 = 0x0A0D0C3A,
    MAGIC_3_1 = 0x0A0D0C4E,
    MAGIC_3_2 = 0x0A0D0C6C,
    MAGIC_3_3 = 0x0A0D0C9E,
    MAGIC_3_4 = 0x0A0D0CEE,
    MAGIC_3_5 = 0x0A0D0D16,
    MAGIC_3_5_3 = 0x0A0D0D17,
    MAGIC_3_6 = 0x0A0D0D33,
    MAGIC_3_7 = 0x0A0D0D42,
    MAGIC_3_8 = 0x0A0D0D55,
    MAGIC_3_9 = 0x0A0D0D61,
    MAGIC_3_10 = 0x0A0D0D6F,
    MAGIC_3_11 = 0x0A0D0DA7,
    MAGIC_3_12 = 0x0A0D0DCB,
    MAGIC_3_13 = 0x0A0D0DF3,
    MAGIC_3_14 = 0x0A0D0E2B,

    _,

    pub fn toVersion(self: Magic) ?Version {
        // First check known enums
        return switch (self) {
            .MAGIC_1_0 => Version.init(1, 0),
            .MAGIC_1_1 => Version.init(1, 1),
            .MAGIC_1_3 => Version.init(1, 3),
            .MAGIC_1_4 => Version.init(1, 4),
            .MAGIC_1_5 => Version.init(1, 5),
            .MAGIC_1_6 => Version.init(1, 6),
            .MAGIC_2_0 => Version.init(2, 0),
            .MAGIC_2_1 => Version.init(2, 1),
            .MAGIC_2_2 => Version.init(2, 2),
            .MAGIC_2_3 => Version.init(2, 3),
            .MAGIC_2_4 => Version.init(2, 4),
            .MAGIC_2_5 => Version.init(2, 5),
            .MAGIC_2_6 => Version.init(2, 6),
            .MAGIC_2_7 => Version.init(2, 7),
            .MAGIC_3_0 => Version.init(3, 0),
            .MAGIC_3_1 => Version.init(3, 1),
            .MAGIC_3_2 => Version.init(3, 2),
            .MAGIC_3_3 => Version.init(3, 3),
            .MAGIC_3_4 => Version.init(3, 4),
            .MAGIC_3_5, .MAGIC_3_5_3 => Version.init(3, 5),
            .MAGIC_3_6 => Version.init(3, 6),
            .MAGIC_3_7 => Version.init(3, 7),
            .MAGIC_3_8 => Version.init(3, 8),
            .MAGIC_3_9 => Version.init(3, 9),
            .MAGIC_3_10 => Version.init(3, 10),
            .MAGIC_3_11 => Version.init(3, 11),
            .MAGIC_3_12 => Version.init(3, 12),
            .MAGIC_3_13 => Version.init(3, 13),
            .MAGIC_3_14 => Version.init(3, 14),
            _ => self.toVersionFromRange(),
        };
    }

    /// For unrecognized magic numbers, try to determine version from magic range.
    /// Python 3.x uses magic numbers in predictable ranges.
    fn toVersionFromRange(self: Magic) ?Version {
        const val: u32 = @intFromEnum(self);
        // Magic format: 0x0A0D{magic16} where magic16 is the magic number
        if ((val & 0xFFFF0000) != 0x0A0D0000) return null;
        const magic16: u16 = @truncate(val);

        // Python 3.0: 3000-3131, Python 3.1: 3141-3151, Python 3.2: 3160-3180
        // Python 3.3: 3190-3230, Python 3.4: 3250-3310, Python 3.5: 3320-3351
        return if (magic16 >= 3000 and magic16 <= 3131) Version.init(3, 0) else if (magic16 >= 3141 and magic16 <= 3151) Version.init(3, 1) else if (magic16 >= 3160 and magic16 <= 3180) Version.init(3, 2) else if (magic16 >= 3190 and magic16 <= 3230) Version.init(3, 3) else if (magic16 >= 3250 and magic16 <= 3310) Version.init(3, 4) else if (magic16 >= 3320 and magic16 <= 3351) Version.init(3, 5) else null;
    }
};

/// Marshal object types used in .pyc files
pub const ObjectType = enum(u8) {
    TYPE_NULL = '0',
    TYPE_NONE = 'N',
    TYPE_FALSE = 'F',
    TYPE_TRUE = 'T',
    TYPE_STOPITER = 'S',
    TYPE_ELLIPSIS = '.',
    TYPE_INT = 'i',
    TYPE_INT64 = 'I',
    TYPE_FLOAT = 'f',
    TYPE_BINARY_FLOAT = 'g',
    TYPE_COMPLEX = 'x',
    TYPE_BINARY_COMPLEX = 'y',
    TYPE_LONG = 'l',
    TYPE_STRING = 's',
    TYPE_INTERNED = 't',
    TYPE_REF = 'r',
    TYPE_STRINGREF = 'R', // Python 2.x: reference to interned string by index
    TYPE_TUPLE = '(',
    TYPE_LIST = '[',
    TYPE_DICT = '{',
    TYPE_CODE = 'c',
    TYPE_UNICODE = 'u',
    TYPE_UNKNOWN = '?',
    TYPE_SET = '<',
    TYPE_FROZENSET = '>',
    TYPE_ASCII = 'a',
    TYPE_ASCII_INTERNED = 'A',
    TYPE_SMALL_TUPLE = ')',
    TYPE_SHORT_ASCII = 'z',
    TYPE_SHORT_ASCII_INTERNED = 'Z',
    TYPE_SLICE = ':', // Python 3.14+ marshal format version 5

    // FLAG_REF can be OR'd with type to indicate the object should be
    // added to the refs list for later reference
    pub const FLAG_REF: u8 = 0x80;

    pub fn fromByte(byte: u8) ObjectType {
        // Strip FLAG_REF before matching
        const type_byte = byte & ~FLAG_REF;
        return std.meta.intToEnum(ObjectType, type_byte) catch .TYPE_UNKNOWN;
    }

    pub fn hasRef(byte: u8) bool {
        return (byte & FLAG_REF) != 0;
    }

    /// Returns true if this object type contains children that need recursive parsing.
    /// These types require pre-allocation in the refs table before parsing children.
    pub fn hasChildren(self: ObjectType) bool {
        return switch (self) {
            .TYPE_TUPLE, .TYPE_SMALL_TUPLE, .TYPE_LIST, .TYPE_SET, .TYPE_FROZENSET, .TYPE_DICT, .TYPE_CODE, .TYPE_SLICE => true,
            else => false,
        };
    }
};

/// Python code object - the main bytecode container
pub const Code = struct {
    allocator: Allocator,

    // Code metadata
    argcount: u32 = 0,
    posonlyargcount: u32 = 0, // 3.8+
    kwonlyargcount: u32 = 0, // 3.0+
    nlocals: u32 = 0,
    stacksize: u32 = 0,
    flags: u32 = 0,

    // Bytecode
    code: []const u8 = &.{},

    // Constants, names, etc.
    consts: []Object = &.{},
    names: [][]const u8 = &.{},
    varnames: [][]const u8 = &.{},
    freevars: [][]const u8 = &.{},
    cellvars: [][]const u8 = &.{},

    // Source info
    filename: []const u8 = &.{},
    name: []const u8 = &.{},
    qualname: []const u8 = &.{}, // 3.11+
    firstlineno: u32 = 0,
    linetable: []const u8 = &.{}, // lnotab in older versions

    // 3.11+ exception table
    exceptiontable: []const u8 = &.{},

    // Code flags
    pub const CO_OPTIMIZED: u32 = 0x0001;
    pub const CO_NEWLOCALS: u32 = 0x0002;
    pub const CO_VARARGS: u32 = 0x0004;
    pub const CO_VARKEYWORDS: u32 = 0x0008;
    pub const CO_NESTED: u32 = 0x0010;
    pub const CO_GENERATOR: u32 = 0x0020;
    pub const CO_NOFREE: u32 = 0x0040;
    pub const CO_COROUTINE: u32 = 0x0080;
    pub const CO_ITERABLE_COROUTINE: u32 = 0x0100;
    pub const CO_ASYNC_GENERATOR: u32 = 0x0200;
    pub const CO_FUTURE_DIVISION: u32 = 0x20000;
    pub const CO_FUTURE_ABSOLUTE_IMPORT: u32 = 0x40000;
    pub const CO_FUTURE_WITH_STATEMENT: u32 = 0x80000;
    pub const CO_FUTURE_PRINT_FUNCTION: u32 = 0x100000;
    pub const CO_FUTURE_UNICODE_LITERALS: u32 = 0x200000;
    pub const CO_FUTURE_ANNOTATIONS: u32 = 0x1000000;

    pub fn deinit(self: *Code) void {
        if (self.code.len > 0) self.allocator.free(self.code);
        for (self.consts) |*obj| obj.deinit(self.allocator);
        if (self.consts.len > 0) self.allocator.free(self.consts);
        for (self.names) |n| self.allocator.free(n);
        if (self.names.len > 0) self.allocator.free(self.names);
        for (self.varnames) |n| self.allocator.free(n);
        if (self.varnames.len > 0) self.allocator.free(self.varnames);
        for (self.freevars) |n| self.allocator.free(n);
        if (self.freevars.len > 0) self.allocator.free(self.freevars);
        for (self.cellvars) |n| self.allocator.free(n);
        if (self.cellvars.len > 0) self.allocator.free(self.cellvars);
        if (self.filename.len > 0) self.allocator.free(self.filename);
        if (self.name.len > 0) self.allocator.free(self.name);
        if (self.qualname.len > 0) self.allocator.free(self.qualname);
        if (self.linetable.len > 0) self.allocator.free(self.linetable);
        if (self.exceptiontable.len > 0) self.allocator.free(self.exceptiontable);
    }
};

/// Python integer representation - either fits in i64 or uses arbitrary precision BigInt.
pub const Int = union(enum) {
    small: i64,
    big: BigInt,

    pub fn fromI64(val: i64) Int {
        return .{ .small = val };
    }

    /// Convert a BigInt to an Int, freeing the BigInt's memory if it fits in i64.
    pub fn fromBigInt(big: BigInt, allocator: Allocator) Int {
        // Try to convert to small if it fits
        if (big.toI64()) |val| {
            // Free the BigInt's digits since we're converting to small
            if (big.digits.len > 0) {
                allocator.free(big.digits);
            }
            return .{ .small = val };
        }
        return .{ .big = big };
    }

    pub fn deinit(self: *Int, allocator: Allocator) void {
        switch (self.*) {
            .big => |*b| b.deinit(allocator),
            .small => {},
        }
    }

    pub fn clone(self: Int, allocator: Allocator) Allocator.Error!Int {
        return switch (self) {
            .small => |v| .{ .small = v },
            .big => |b| .{ .big = try b.clone(allocator) },
        };
    }

    pub fn format(
        self: Int,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .small => |v| try writer.print("{d}", .{v}),
            .big => |b| try b.format("", .{}, writer),
        }
    }
};

/// Generic Python object for constants
pub const Object = union(enum) {
    none,
    true_val,
    false_val,
    ellipsis,
    stop_iteration,
    int: Int,
    float: f64,
    complex: struct { real: f64, imag: f64 },
    string: []const u8,
    bytes: []const u8,
    tuple: []Object,
    list: []Object,
    set: []Object,
    frozenset: []Object,
    dict: []struct { key: Object, value: Object },
    code: *Code,
    /// Non-owning reference to a code object (from TYPE_REF resolution)
    code_ref: *Code,
    slice: struct { start: *Object, stop: *Object, step: *Object },

    pub fn deinit(self: *Object, allocator: Allocator) void {
        switch (self.*) {
            .int => |*i| i.deinit(allocator),
            .string, .bytes => |s| if (s.len > 0) allocator.free(s),
            .tuple, .list, .set, .frozenset => |items| {
                for (items) |*item| item.deinit(allocator);
                if (items.len > 0) allocator.free(items);
            },
            .slice => |*s| {
                s.start.deinit(allocator);
                allocator.destroy(s.start);
                s.stop.deinit(allocator);
                allocator.destroy(s.stop);
                s.step.deinit(allocator);
                allocator.destroy(s.step);
            },
            .dict => |entries| {
                for (entries) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                if (entries.len > 0) allocator.free(entries);
            },
            .code => |c| {
                c.deinit();
                allocator.destroy(c);
            },
            .code_ref => {}, // Non-owning reference - don't free
            else => {},
        }
    }

    pub fn format(
        self: Object,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .none => try writer.writeAll("None"),
            .true_val => try writer.writeAll("True"),
            .false_val => try writer.writeAll("False"),
            .ellipsis => try writer.writeAll("..."),
            .stop_iteration => try writer.writeAll("StopIteration"),
            .int => |v| try v.format("", .{}, writer),
            .float => |v| try writer.print("{d}", .{v}),
            .complex => |v| {
                if (v.imag >= 0) {
                    try writer.print("({d}+{d}j)", .{ v.real, v.imag });
                } else {
                    try writer.print("({d}{d}j)", .{ v.real, v.imag });
                }
            },
            .string => |s| try writer.print("'{s}'", .{s}),
            .bytes => |b| try writer.print("b'{s}'", .{b}),
            .tuple => |items| {
                try writer.writeByte('(');
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                if (items.len == 1) try writer.writeByte(',');
                try writer.writeByte(')');
            },
            .list => |items| {
                try writer.writeByte('[');
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeByte(']');
            },
            .set => |items| {
                try writer.writeByte('{');
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeByte('}');
            },
            .frozenset => |items| {
                try writer.writeAll("frozenset({");
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeAll("})");
            },
            .dict => |entries| {
                try writer.writeByte('{');
                for (entries, 0..) |entry, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try entry.key.format("", .{}, writer);
                    try writer.writeAll(": ");
                    try entry.value.format("", .{}, writer);
                }
                try writer.writeByte('}');
            },
            .slice => |s| {
                try writer.writeAll("slice(");
                try s.start.format("", .{}, writer);
                try writer.writeAll(", ");
                try s.stop.format("", .{}, writer);
                try writer.writeAll(", ");
                try s.step.format("", .{}, writer);
                try writer.writeByte(')');
            },
            .code, .code_ref => |c| try writer.print("<code '{s}'>", .{c.name}),
        }
    }

    /// Deep clone an object, duplicating all owned data
    /// For code objects, returns a non-owning reference (code_ref)
    pub fn clone(self: Object, allocator: Allocator) Allocator.Error!Object {
        return switch (self) {
            .none, .true_val, .false_val, .ellipsis, .stop_iteration, .float, .complex => self,
            .int => |i| .{ .int = try i.clone(allocator) },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
            .tuple => |items| blk: {
                const new_items = try allocator.alloc(Object, items.len);
                errdefer allocator.free(new_items);
                for (items, 0..) |item, i| {
                    new_items[i] = try item.clone(allocator);
                }
                break :blk .{ .tuple = new_items };
            },
            .list => |items| blk: {
                const new_items = try allocator.alloc(Object, items.len);
                errdefer allocator.free(new_items);
                for (items, 0..) |item, i| {
                    new_items[i] = try item.clone(allocator);
                }
                break :blk .{ .list = new_items };
            },
            .set => |items| blk: {
                const new_items = try allocator.alloc(Object, items.len);
                errdefer allocator.free(new_items);
                for (items, 0..) |item, i| {
                    new_items[i] = try item.clone(allocator);
                }
                break :blk .{ .set = new_items };
            },
            .frozenset => |items| blk: {
                const new_items = try allocator.alloc(Object, items.len);
                errdefer allocator.free(new_items);
                for (items, 0..) |item, i| {
                    new_items[i] = try item.clone(allocator);
                }
                break :blk .{ .frozenset = new_items };
            },
            .dict => |entries| blk: {
                const DictEntry = @typeInfo(@FieldType(Object, "dict")).pointer.child;
                const new_entries = try allocator.alloc(DictEntry, entries.len);
                errdefer allocator.free(new_entries);
                for (entries, 0..) |entry, i| {
                    new_entries[i] = .{
                        .key = try entry.key.clone(allocator),
                        .value = try entry.value.clone(allocator),
                    };
                }
                break :blk .{ .dict = new_entries };
            },
            .slice => |s| blk: {
                const start_ptr = try allocator.create(Object);
                start_ptr.* = try s.start.clone(allocator);
                errdefer {
                    start_ptr.deinit(allocator);
                    allocator.destroy(start_ptr);
                }

                const stop_ptr = try allocator.create(Object);
                stop_ptr.* = try s.stop.clone(allocator);
                errdefer {
                    stop_ptr.deinit(allocator);
                    allocator.destroy(stop_ptr);
                }

                const step_ptr = try allocator.create(Object);
                step_ptr.* = try s.step.clone(allocator);
                errdefer {
                    step_ptr.deinit(allocator);
                    allocator.destroy(step_ptr);
                }

                break :blk .{ .slice = .{
                    .start = start_ptr,
                    .stop = stop_ptr,
                    .step = step_ptr,
                } };
            },
            .code, .code_ref => |c| .{ .code_ref = c }, // Return non-owning reference
        };
    }
};

/// Buffer reader for parsing .pyc data
const BufferReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readByte(self: *BufferReader) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfFile;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU16(self: *BufferReader) !u16 {
        if (self.pos + 2 > self.data.len) return error.UnexpectedEndOfFile;
        const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return val;
    }

    fn readU32(self: *BufferReader) !u32 {
        if (self.pos + 4 > self.data.len) return error.UnexpectedEndOfFile;
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readI32(self: *BufferReader) !i32 {
        if (self.pos + 4 > self.data.len) return error.UnexpectedEndOfFile;
        const val = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readI64(self: *BufferReader) !i64 {
        if (self.pos + 8 > self.data.len) return error.UnexpectedEndOfFile;
        const val = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    fn readU64(self: *BufferReader) !u64 {
        if (self.pos + 8 > self.data.len) return error.UnexpectedEndOfFile;
        const val = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    fn readSlice(self: *BufferReader, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.UnexpectedEndOfFile;
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    fn skip(self: *BufferReader, len: usize) !void {
        if (self.pos + len > self.data.len) return error.UnexpectedEndOfFile;
        self.pos += len;
    }
};

/// Main module - represents a loaded .pyc file
pub const Module = struct {
    allocator: Allocator,
    major_ver: u8 = 0,
    minor_ver: u8 = 0,
    code: ?*Code = null,
    interns: std.ArrayList([]const u8) = .{},
    refs: std.ArrayList(Object) = .{},
    file_data: ?[]const u8 = null,

    pub fn init(allocator: Allocator) Module {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Module) void {
        if (self.code) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        for (self.interns.items) |s| self.allocator.free(s);
        self.interns.deinit(self.allocator);
        // Free refs - but skip code objects as they're owned elsewhere
        for (self.refs.items) |*obj| {
            switch (obj.*) {
                .code => {}, // Don't free - owned by parent code object or module
                else => obj.deinit(self.allocator),
            }
        }
        self.refs.deinit(self.allocator);
        if (self.file_data) |data| self.allocator.free(data);
    }

    pub fn version(self: *const Module) Version {
        return Version.init(self.major_ver, self.minor_ver);
    }

    pub fn loadFromFile(self: *Module, filename: []const u8) !void {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        // Read entire file into memory
        const stat = try file.stat();
        const data = try self.allocator.alloc(u8, stat.size);
        errdefer {
            if (self.file_data == null) self.allocator.free(data);
        }

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) return error.UnexpectedEndOfFile;

        self.file_data = data;

        var reader = BufferReader{ .data = data };

        // Read magic number
        const magic_val = try reader.readU32();
        const magic: Magic = @enumFromInt(magic_val);

        const ver = magic.toVersion() orelse return error.UnsupportedPythonVersion;
        self.major_ver = ver.major;
        self.minor_ver = ver.minor;

        // Skip header (size varies by version)
        if (ver.gte(3, 7)) {
            const flags = try reader.readU32();
            if ((flags & 0x01) != 0) {
                try reader.skip(8); // Hash-based pyc
            } else {
                try reader.skip(8); // Timestamp-based
            }
        } else if (ver.gte(3, 3)) {
            try reader.skip(8); // timestamp + source size
        } else {
            try reader.skip(4); // timestamp only
        }

        // Read marshalled code object
        self.code = try self.readObject(&reader);
    }

    fn readObject(self: *Module, reader: *BufferReader) !?*Code {
        const type_byte = try reader.readByte();
        const obj_type = ObjectType.fromByte(type_byte);
        const add_ref = ObjectType.hasRef(type_byte);

        // Reserve slot in refs BEFORE parsing children (they may reference this object)
        const ref_idx: ?usize = if (add_ref and obj_type == .TYPE_CODE) blk: {
            const idx = self.refs.items.len;
            try self.refs.append(self.allocator, .none); // Placeholder
            break :blk idx;
        } else null;

        const code: ?*Code = switch (obj_type) {
            .TYPE_CODE => try self.readCode(reader),
            else => null,
        };

        // Update placeholder with actual code object
        if (ref_idx) |idx| {
            if (code) |c| {
                self.refs.items[idx] = .{ .code = c };
            }
        }

        return code;
    }

    const ParseError = error{
        UnexpectedEndOfFile,
        OutOfMemory,
        UnsupportedPythonVersion,
        InvalidRef,
        InvalidStringRef,
    };

    fn readCode(self: *Module, reader: *BufferReader) ParseError!*Code {
        const allocator = self.allocator;
        const ver = self.version();

        var code = try allocator.create(Code);
        errdefer allocator.destroy(code);
        code.* = .{ .allocator = allocator };

        // Read code object fields (order varies by version)
        if (ver.gte(3, 11)) {
            // Python 3.11+ removed nlocals from marshal format
            code.argcount = try reader.readU32();
            code.posonlyargcount = try reader.readU32();
            code.kwonlyargcount = try reader.readU32();
            code.stacksize = try reader.readU32();
            code.flags = try reader.readU32();
        } else if (ver.gte(3, 8)) {
            code.argcount = try reader.readU32();
            code.posonlyargcount = try reader.readU32();
            code.kwonlyargcount = try reader.readU32();
            code.nlocals = try reader.readU32();
            code.stacksize = try reader.readU32();
            code.flags = try reader.readU32();
        } else if (ver.gte(3, 0)) {
            code.argcount = try reader.readU32();
            code.kwonlyargcount = try reader.readU32();
            code.nlocals = try reader.readU32();
            code.stacksize = try reader.readU32();
            code.flags = try reader.readU32();
        } else if (ver.gte(2, 3)) {
            // Python 2.3-2.7: 32-bit fields
            code.argcount = try reader.readU32();
            code.nlocals = try reader.readU32();
            code.stacksize = try reader.readU32();
            code.flags = try reader.readU32();
        } else if (ver.gte(1, 5)) {
            // Python 1.5-2.2: 16-bit fields
            code.argcount = try reader.readU16();
            code.nlocals = try reader.readU16();
            code.stacksize = try reader.readU16();
            code.flags = try reader.readU16();
        } else if (ver.gte(1, 3)) {
            // Python 1.3-1.4: no stacksize
            code.argcount = try reader.readU16();
            code.nlocals = try reader.readU16();
            code.flags = try reader.readU16();
        } else {
            // Python 1.0-1.2: no argcount
            code.nlocals = try reader.readU16();
            code.flags = try reader.readU16();
        }

        // Read bytecode
        code.code = try self.readBytesAlloc(reader);

        // Read constants
        code.consts = try self.readTupleObjects(reader);

        // Read names tuple
        code.names = try self.readTupleStrings(reader);

        if (ver.gte(3, 11)) {
            // Python 3.11+ uses localsplusnames and localspluskinds
            // instead of varnames, freevars, cellvars
            code.varnames = try self.readTupleStrings(reader); // localsplusnames
            const localspluskinds = try self.readBytesAlloc(reader);
            if (localspluskinds.len > 0) allocator.free(localspluskinds); // discard for now
            code.freevars = &.{};
            code.cellvars = &.{};
        } else if (ver.gte(2, 1)) {
            // Python 2.1+: varnames, freevars, cellvars
            code.varnames = try self.readTupleStrings(reader);
            code.freevars = try self.readTupleStrings(reader);
            code.cellvars = try self.readTupleStrings(reader);
        } else if (ver.gte(1, 3)) {
            // Python 1.3-2.0: varnames only
            code.varnames = try self.readTupleStrings(reader);
            code.freevars = &.{};
            code.cellvars = &.{};
        } else {
            // Python 1.0-1.2: no varnames
            code.varnames = &.{};
            code.freevars = &.{};
            code.cellvars = &.{};
        }

        code.filename = try self.readStringAlloc(reader);
        code.name = try self.readStringAlloc(reader);

        if (ver.gte(3, 11)) {
            code.qualname = try self.readStringAlloc(reader);
        }

        if (ver.gte(2, 3)) {
            // Python 2.3+: 32-bit firstlineno
            code.firstlineno = try reader.readU32();
            code.linetable = try self.readBytesAlloc(reader);
        } else if (ver.gte(1, 5)) {
            // Python 1.5-2.2: 16-bit firstlineno
            code.firstlineno = try reader.readU16();
            code.linetable = try self.readBytesAlloc(reader);
        } else if (ver.gte(1, 3)) {
            // Python 1.3-1.4: 16-bit firstlineno, no lnotab
            code.firstlineno = try reader.readU16();
            code.linetable = &.{};
        } else {
            // Python 1.0-1.2: no firstlineno or lnotab
            code.firstlineno = 0;
            code.linetable = &.{};
        }

        if (ver.gte(3, 11)) {
            code.exceptiontable = try self.readBytesAlloc(reader);
        }

        return code;
    }

    fn readBytesAlloc(self: *Module, reader: *BufferReader) ParseError![]const u8 {
        const type_byte = try reader.readByte();
        const obj_type = ObjectType.fromByte(type_byte);
        const add_ref = ObjectType.hasRef(type_byte);

        // Handle TYPE_REF - lookup in refs table
        if (obj_type == .TYPE_REF) {
            const ref_idx = try reader.readU32();
            if (ref_idx >= self.refs.items.len) return error.InvalidRef;
            const obj = self.refs.items[ref_idx];
            return switch (obj) {
                .string => |s| try self.allocator.dupe(u8, s),
                .bytes => |b| try self.allocator.dupe(u8, b),
                .none => error.InvalidRef, // Placeholder - should not be referenced
                else => &.{}, // Type mismatch - return empty
            };
        }

        // TYPE_STRINGREF - Python 2.x reference to interned string by index
        if (obj_type == .TYPE_STRINGREF) {
            const ref_idx = try reader.readU32();
            if (ref_idx >= self.interns.items.len) return error.InvalidRef;
            return try self.allocator.dupe(u8, self.interns.items[ref_idx]);
        }

        const len: usize = switch (obj_type) {
            .TYPE_STRING, .TYPE_ASCII, .TYPE_INTERNED, .TYPE_ASCII_INTERNED, .TYPE_UNICODE => try reader.readU32(),
            .TYPE_SHORT_ASCII, .TYPE_SHORT_ASCII_INTERNED => try reader.readByte(),
            else => return &.{},
        };

        const slice = try reader.readSlice(len);
        const str = try self.allocator.dupe(u8, slice);

        // Track interned strings (interns owns its own copy)
        const is_interned = obj_type == .TYPE_INTERNED or
            obj_type == .TYPE_ASCII_INTERNED or
            obj_type == .TYPE_SHORT_ASCII_INTERNED;
        if (is_interned) {
            try self.interns.append(self.allocator, try self.allocator.dupe(u8, slice));
        }

        // Add to refs if FLAG_REF is set (refs owns its own copy)
        if (add_ref) {
            try self.refs.append(self.allocator, .{ .string = try self.allocator.dupe(u8, slice) });
        }

        return str;
    }

    fn readStringAlloc(self: *Module, reader: *BufferReader) ParseError![]const u8 {
        return self.readBytesAlloc(reader);
    }

    fn readTupleStrings(self: *Module, reader: *BufferReader) ParseError![][]const u8 {
        const type_byte = try reader.readByte();
        const obj_type = ObjectType.fromByte(type_byte);
        const add_ref = ObjectType.hasRef(type_byte);

        // Handle TYPE_REF - look up in refs table
        if (obj_type == .TYPE_REF) {
            const ref_idx = try reader.readU32();
            if (ref_idx >= self.refs.items.len) return error.InvalidRef;
            const ref_obj = self.refs.items[ref_idx];
            if (ref_obj == .none) return error.InvalidRef; // Placeholder - should not be referenced
            if (ref_obj != .tuple) return &.{}; // Type mismatch
            // Convert tuple of Objects to array of strings
            const tuple = ref_obj.tuple;
            const strings = try self.allocator.alloc([]const u8, tuple.len);
            for (tuple, 0..) |obj, i| {
                if (obj == .string) {
                    strings[i] = try self.allocator.dupe(u8, obj.string);
                } else {
                    strings[i] = &.{};
                }
            }
            return strings;
        }

        const count: usize = switch (obj_type) {
            .TYPE_TUPLE => try reader.readU32(),
            .TYPE_SMALL_TUPLE => try reader.readByte(),
            else => return &.{},
        };

        // Reserve slot in refs BEFORE parsing children (they may reference this tuple)
        const ref_idx: ?usize = if (add_ref) blk: {
            const idx = self.refs.items.len;
            try self.refs.append(self.allocator, .none); // Placeholder
            break :blk idx;
        } else null;

        const strings = try self.allocator.alloc([]const u8, count);
        errdefer {
            for (strings) |s| self.allocator.free(s);
            self.allocator.free(strings);
        }

        for (strings) |*s| {
            s.* = try self.readStringAlloc(reader);
        }

        // If FLAG_REF is set, update placeholder with actual tuple
        if (ref_idx) |idx| {
            const objs = try self.allocator.alloc(Object, count);
            for (strings, 0..) |s, i| {
                objs[i] = .{ .string = try self.allocator.dupe(u8, s) };
            }
            self.refs.items[idx] = .{ .tuple = objs };
        }

        return strings;
    }

    fn readTupleObjects(self: *Module, reader: *BufferReader) ParseError![]Object {
        const type_byte = try reader.readByte();
        const obj_type = ObjectType.fromByte(type_byte);
        const add_ref = ObjectType.hasRef(type_byte);

        // Handle TYPE_REF - look up in refs table
        if (obj_type == .TYPE_REF) {
            const ref_idx = try reader.readU32();
            if (ref_idx >= self.refs.items.len) return error.InvalidRef;
            const ref_obj = self.refs.items[ref_idx];
            if (ref_obj == .none) return error.InvalidRef; // Placeholder - should not be referenced
            if (ref_obj != .tuple) return &.{}; // Type mismatch
            // Clone the tuple
            const tuple = ref_obj.tuple;
            const objects = try self.allocator.alloc(Object, tuple.len);
            for (tuple, 0..) |obj, i| {
                objects[i] = try obj.clone(self.allocator);
            }
            return objects;
        }

        const count: usize = switch (obj_type) {
            .TYPE_TUPLE => try reader.readU32(),
            .TYPE_SMALL_TUPLE => try reader.readByte(),
            else => return &.{},
        };

        // Reserve slot in refs BEFORE parsing children (they may reference this tuple)
        const ref_idx: ?usize = if (add_ref) blk: {
            const idx = self.refs.items.len;
            try self.refs.append(self.allocator, .none); // Placeholder
            break :blk idx;
        } else null;

        const objects = try self.allocator.alloc(Object, count);
        var initialized: usize = 0;
        errdefer {
            for (objects[0..initialized]) |*o| o.deinit(self.allocator);
            self.allocator.free(objects);
        }

        for (objects) |*obj| {
            obj.* = try self.readAnyObject(reader);
            initialized += 1;
        }

        // If FLAG_REF is set, update the placeholder with actual tuple
        if (ref_idx) |idx| {
            const ref_objs = try self.allocator.alloc(Object, count);
            for (objects, 0..) |obj, i| {
                ref_objs[i] = try obj.clone(self.allocator);
            }
            self.refs.items[idx] = .{ .tuple = ref_objs };
        }

        return objects;
    }

    fn readAnyObject(self: *Module, reader: *BufferReader) ParseError!Object {
        const type_byte = try reader.readByte();
        const obj_type = ObjectType.fromByte(type_byte);
        const add_ref = ObjectType.hasRef(type_byte);

        // Handle TYPE_REF first - it returns a clone of a previously seen object
        if (obj_type == .TYPE_REF) {
            const ref_idx = try reader.readU32();
            if (ref_idx >= self.refs.items.len) return error.InvalidRef;
            const ref_obj = self.refs.items[ref_idx];
            if (ref_obj == .none) return error.InvalidRef; // Placeholder - should not be referenced
            return ref_obj.clone(self.allocator);
        }

        // For compound objects (those with children), we must reserve a slot in refs
        // BEFORE parsing children, so that children can reference this object.
        // We use .none as a placeholder then update it after parsing.
        const ref_idx: ?usize = if (add_ref and obj_type.hasChildren()) blk: {
            const idx = self.refs.items.len;
            try self.refs.append(self.allocator, .none); // Placeholder
            break :blk idx;
        } else null;

        // Parse the object based on type
        const obj: Object = switch (obj_type) {
            .TYPE_NONE => .none,
            .TYPE_TRUE => .true_val,
            .TYPE_FALSE => .false_val,
            .TYPE_ELLIPSIS => .ellipsis,
            .TYPE_STOPITER => .stop_iteration,
            .TYPE_INT => .{ .int = Int.fromI64(try reader.readI32()) },
            .TYPE_INT64 => .{ .int = Int.fromI64(try reader.readI64()) },
            .TYPE_LONG => blk: {
                const size = try reader.readI32();
                const negative = size < 0;
                const digit_count: usize = @intCast(if (size < 0) -size else size);
                const big = try BigInt.init(self.allocator, digit_count, negative, reader);
                break :blk .{ .int = Int.fromBigInt(big, self.allocator) };
            },
            .TYPE_BINARY_FLOAT => .{ .float = @bitCast(try reader.readU64()) },
            .TYPE_FLOAT => blk: {
                // Text-based float: 1-byte length followed by ASCII decimal representation
                const len = try reader.readByte();
                const slice = try reader.readSlice(len);
                const value = std.fmt.parseFloat(f64, slice) catch 0.0;
                break :blk .{ .float = value };
            },
            .TYPE_COMPLEX => blk: {
                // Text-based complex: two text floats (real and imaginary)
                const real_len = try reader.readByte();
                const real_slice = try reader.readSlice(real_len);
                const real = std.fmt.parseFloat(f64, real_slice) catch 0.0;
                const imag_len = try reader.readByte();
                const imag_slice = try reader.readSlice(imag_len);
                const imag = std.fmt.parseFloat(f64, imag_slice) catch 0.0;
                break :blk .{ .complex = .{ .real = real, .imag = imag } };
            },
            .TYPE_BINARY_COMPLEX => blk: {
                // Binary complex: two 64-bit IEEE floats
                const real: f64 = @bitCast(try reader.readU64());
                const imag: f64 = @bitCast(try reader.readU64());
                break :blk .{ .complex = .{ .real = real, .imag = imag } };
            },
            .TYPE_STRING, .TYPE_ASCII => blk: {
                const len = try reader.readU32();
                const slice = try reader.readSlice(len);
                break :blk .{ .string = try self.allocator.dupe(u8, slice) };
            },
            .TYPE_INTERNED, .TYPE_ASCII_INTERNED => blk: {
                const len = try reader.readU32();
                const slice = try reader.readSlice(len);
                const str = try self.allocator.dupe(u8, slice);
                // Add a copy to interns list for TYPE_STRINGREF lookups (interns owns its copies)
                try self.interns.append(self.allocator, try self.allocator.dupe(u8, slice));
                break :blk .{ .string = str };
            },
            .TYPE_SHORT_ASCII => blk: {
                const len = try reader.readByte();
                const slice = try reader.readSlice(len);
                break :blk .{ .string = try self.allocator.dupe(u8, slice) };
            },
            .TYPE_SHORT_ASCII_INTERNED => blk: {
                const len = try reader.readByte();
                const slice = try reader.readSlice(len);
                const str = try self.allocator.dupe(u8, slice);
                // Add a copy to interns list for TYPE_STRINGREF lookups (interns owns its copies)
                try self.interns.append(self.allocator, try self.allocator.dupe(u8, slice));
                break :blk .{ .string = str };
            },
            .TYPE_STRINGREF => blk: {
                // Python 2.x: reference to interned string by index
                const idx = try reader.readU32();
                if (idx >= self.interns.items.len) return error.InvalidStringRef;
                break :blk .{ .string = try self.allocator.dupe(u8, self.interns.items[idx]) };
            },
            .TYPE_UNICODE => blk: {
                const len = try reader.readU32();
                const slice = try reader.readSlice(len);
                break :blk .{ .string = try self.allocator.dupe(u8, slice) };
            },
            .TYPE_TUPLE, .TYPE_SMALL_TUPLE => blk: {
                const count: usize = if (obj_type == .TYPE_SMALL_TUPLE)
                    try reader.readByte()
                else
                    try reader.readU32();

                const items = try self.allocator.alloc(Object, count);
                var items_initialized: usize = 0;
                errdefer {
                    for (items[0..items_initialized]) |*item| item.deinit(self.allocator);
                    self.allocator.free(items);
                }

                for (items) |*item| {
                    item.* = try self.readAnyObject(reader);
                    items_initialized += 1;
                }

                break :blk .{ .tuple = items };
            },
            .TYPE_LIST => blk: {
                const count = try reader.readU32();

                const items = try self.allocator.alloc(Object, count);
                var items_initialized: usize = 0;
                errdefer {
                    for (items[0..items_initialized]) |*item| item.deinit(self.allocator);
                    self.allocator.free(items);
                }

                for (items) |*item| {
                    item.* = try self.readAnyObject(reader);
                    items_initialized += 1;
                }

                break :blk .{ .list = items };
            },
            .TYPE_SET, .TYPE_FROZENSET => blk: {
                const count = try reader.readU32();

                const items = try self.allocator.alloc(Object, count);
                var items_initialized: usize = 0;
                errdefer {
                    for (items[0..items_initialized]) |*item| item.deinit(self.allocator);
                    self.allocator.free(items);
                }

                for (items) |*item| {
                    item.* = try self.readAnyObject(reader);
                    items_initialized += 1;
                }

                break :blk if (obj_type == .TYPE_SET) .{ .set = items } else .{ .frozenset = items };
            },
            .TYPE_DICT => blk: {
                // Dict entries are key-value pairs until TYPE_NULL sentinel
                const DictEntry = @typeInfo(@FieldType(Object, "dict")).pointer.child;
                var entries: std.ArrayList(DictEntry) = .{};
                errdefer {
                    for (entries.items) |*e| {
                        e.key.deinit(self.allocator);
                        e.value.deinit(self.allocator);
                    }
                    entries.deinit(self.allocator);
                }

                while (true) {
                    // Peek at type byte to check for TYPE_NULL sentinel
                    const type_byte_peek = try reader.readByte();
                    const peek_type = ObjectType.fromByte(type_byte_peek);
                    if (peek_type == .TYPE_NULL) {
                        // TYPE_NULL ('0') signals end of dict
                        break;
                    }
                    // Put the byte back by rewinding
                    reader.pos -= 1;

                    const key = try self.readAnyObject(reader);
                    errdefer {
                        var k = key;
                        k.deinit(self.allocator);
                    }
                    const value = try self.readAnyObject(reader);
                    try entries.append(self.allocator, .{ .key = key, .value = value });
                }

                break :blk .{ .dict = try entries.toOwnedSlice(self.allocator) };
            },
            .TYPE_CODE => blk: {
                const code = try self.readCode(reader);
                break :blk .{ .code = code };
            },
            .TYPE_SLICE => blk: {
                const start_ptr = try self.allocator.create(Object);
                start_ptr.* = try self.readAnyObject(reader);
                errdefer {
                    start_ptr.deinit(self.allocator);
                    self.allocator.destroy(start_ptr);
                }

                const stop_ptr = try self.allocator.create(Object);
                stop_ptr.* = try self.readAnyObject(reader);
                errdefer {
                    stop_ptr.deinit(self.allocator);
                    self.allocator.destroy(stop_ptr);
                }

                const step_ptr = try self.allocator.create(Object);
                step_ptr.* = try self.readAnyObject(reader);
                errdefer {
                    step_ptr.deinit(self.allocator);
                    self.allocator.destroy(step_ptr);
                }

                break :blk .{ .slice = .{
                    .start = start_ptr,
                    .stop = stop_ptr,
                    .step = step_ptr,
                } };
            },
            .TYPE_REF => unreachable, // Handled above
            else => .none,
        };

        // If FLAG_REF is set, add/update refs entry
        if (add_ref) {
            // Clone the object for the refs table since the original will be owned by caller
            const ref_obj = try obj.clone(self.allocator);
            if (ref_idx) |idx| {
                // Update the placeholder we reserved earlier (compound object)
                self.refs.items[idx] = ref_obj;
            } else {
                // Simple object - just append
                try self.refs.append(self.allocator, ref_obj);
            }
        }

        return obj;
    }

    /// Disassemble the module's code to the writer
    pub fn disassemble(self: *const Module, writer: anytype) !void {
        if (self.code) |code| {
            try self.disassembleCodeWithNested(code, writer, 0);
        }
    }

    fn writeIndent(writer: anytype, indent: usize) !void {
        for (0..indent) |_| try writer.writeByte(' ');
    }

    fn disassembleCode(self: *const Module, code: *const Code, writer: anytype, indent: usize) !void {
        // Print code object header
        try writeIndent(writer, indent);
        try writer.print("# Code object: {s}\n", .{code.name});
        try writeIndent(writer, indent);
        try writer.print("# Args: {d}, Locals: {d}, Stack: {d}, Flags: 0x{x}\n", .{
            code.argcount,
            code.nlocals,
            code.stacksize,
            code.flags,
        });

        // Disassemble bytecode
        const ver = self.version();
        const bytecode = code.code;
        var i: usize = 0;

        // In Python 3.6+, bytecode is word-based: each instruction is 2 bytes
        // (opcode byte + argument byte). Even no-arg opcodes have an arg byte (0).
        const word_based = ver.gte(3, 6);

        while (i < bytecode.len) {
            const op_byte = bytecode[i];
            const opcode = opcodes.byteToOpcode(ver, op_byte) orelse .INVALID;

            try writeIndent(writer, indent);
            try writer.print("{d:>4}  {s:<24}", .{ i, opcode.name() });

            i += 1;

            // Handle argument
            if (word_based) {
                // In Python 3.6+, all instructions have an arg byte
                if (i < bytecode.len) {
                    const arg: u32 = bytecode[i];
                    i += 1;

                    // Only display arg for opcodes that use it
                    if (opcode.hasArg(ver)) {
                        try writer.print(" {d}", .{arg});
                        try self.writeOpcodeAnnotation(writer, opcode, arg, code, ver);
                    }
                }

                // Skip inline cache entries (Python 3.11+)
                // Each cache entry is a 2-byte word
                const cache_count = opcodes.cacheEntries(opcode, ver);
                i += @as(usize, cache_count) * 2;
            } else {
                // Pre-3.6: variable-size instructions
                if (opcode.hasArg(ver) and i + 1 < bytecode.len) {
                    const arg: u32 = @as(u32, bytecode[i]) | (@as(u32, bytecode[i + 1]) << 8);
                    i += 2;
                    try writer.print(" {d}", .{arg});
                    try self.writeOpcodeAnnotation(writer, opcode, arg, code, ver);
                }
            }

            try writer.writeByte('\n');
        }
    }

    fn writeOpcodeAnnotation(self: *const Module, writer: anytype, opcode: opcodes.Opcode, arg: u32, code: *const Code, ver: Version) !void {
        _ = self;
        switch (opcode) {
            .LOAD_CONST => {
                if (arg < code.consts.len) {
                    try writer.writeAll("  # ");
                    try code.consts[arg].format("", .{}, writer);
                }
            },
            .LOAD_NAME, .STORE_NAME, .DELETE_NAME, .LOAD_ATTR, .STORE_ATTR, .DELETE_ATTR, .LOAD_GLOBAL, .STORE_GLOBAL, .DELETE_GLOBAL, .IMPORT_NAME, .IMPORT_FROM => {
                if (arg < code.names.len) {
                    try writer.print("  # {s}", .{code.names[arg]});
                }
            },
            .LOAD_FAST, .STORE_FAST, .DELETE_FAST, .LOAD_FAST_BORROW, .LOAD_FAST_CHECK, .LOAD_FAST_AND_CLEAR => {
                if (arg < code.varnames.len) {
                    try writer.print("  # {s}", .{code.varnames[arg]});
                }
            },
            .COMPARE_OP => {
                // In Python 3.13+, COMPARE_OP uses 5 bits for flags, so op = arg >> 5
                // In Python 3.12, COMPARE_OP uses 4 bits for flags, so op = arg >> 4
                // In Python < 3.12, arg is just the operation index
                const cmp_op: u8 = if (ver.gte(3, 13))
                    @truncate(arg >> 5)
                else if (ver.gte(3, 12))
                    @truncate(arg >> 4)
                else
                    @truncate(arg);

                if (cmp_op < 6) {
                    const cmp: opcodes.CompareOp = @enumFromInt(cmp_op);
                    try writer.print("  # {s}", .{cmp.symbol()});
                }
            },
            .BINARY_OP => {
                if (arg < 26) {
                    const bin_op: opcodes.BinaryOp = @enumFromInt(arg);
                    try writer.print("  # {s}", .{bin_op.symbol()});
                }
            },
            else => {},
        }
    }

    fn disassembleCodeWithNested(self: *const Module, code: *const Code, writer: anytype, indent: usize) !void {
        try self.disassembleCode(code, writer, indent);

        // Recursively disassemble nested code objects
        for (code.consts) |const_obj| {
            switch (const_obj) {
                .code, .code_ref => |c| {
                    try writer.writeByte('\n');
                    try self.disassembleCodeWithNested(c, writer, indent + 2);
                },
                else => {},
            }
        }
    }
};

test "magic number parsing" {
    const testing = std.testing;

    const m311 = Magic.MAGIC_3_11;
    const v = m311.toVersion().?;
    try testing.expectEqual(@as(u8, 3), v.major);
    try testing.expectEqual(@as(u8, 11), v.minor);

    const m27 = Magic.MAGIC_2_7;
    const v2 = m27.toVersion().?;
    try testing.expectEqual(@as(u8, 2), v2.major);
    try testing.expectEqual(@as(u8, 7), v2.minor);
}

test "object type parsing" {
    const testing = std.testing;

    try testing.expectEqual(ObjectType.TYPE_CODE, ObjectType.fromByte('c'));
    try testing.expectEqual(ObjectType.TYPE_STRING, ObjectType.fromByte('s'));
    try testing.expectEqual(ObjectType.TYPE_TUPLE, ObjectType.fromByte('('));

    // Test with FLAG_REF
    try testing.expectEqual(ObjectType.TYPE_CODE, ObjectType.fromByte('c' | 0x80));
    try testing.expect(ObjectType.hasRef('c' | 0x80));
    try testing.expect(!ObjectType.hasRef('c'));
}

test "buffer reader" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var reader = BufferReader{ .data = &data };

    try std.testing.expectEqual(@as(u8, 0x01), try reader.readByte());
    try std.testing.expectEqual(@as(u32, 0x05040302), try reader.readU32());
}

test "TYPE_REF with invalid index returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // TYPE_REF ('r' = 0x72) followed by index 99 (out of bounds since refs is empty)
    const data = [_]u8{ 'r', 99, 0, 0, 0 };
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    const result = module.readAnyObject(&reader);
    try testing.expectError(error.InvalidRef, result);
}

test "TYPE_REF with valid index returns cloned object" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    // Pre-populate refs with a string object
    const test_str = try allocator.dupe(u8, "hello");
    try module.refs.append(allocator, .{ .string = test_str });

    // TYPE_REF ('r' = 0x72) followed by index 0
    const data = [_]u8{ 'r', 0, 0, 0, 0 };
    var reader = BufferReader{ .data = &data };

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("hello", obj.string);
}

test "BigInt zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // TYPE_LONG ('l') with size=0
    const data = [_]u8{ 'l', 0, 0, 0, 0 };
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, 0), obj.int.small);
}

test "BigInt small positive" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // TYPE_LONG ('l') with size=1, digit=12345 (0x3039)
    // This fits in i64 so should become Int.small
    const data = [_]u8{ 'l', 1, 0, 0, 0, 0x39, 0x30 };
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, 12345), obj.int.small);
}

test "BigInt small negative" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // TYPE_LONG ('l') with size=-1 (negative), digit=12345
    const size_bytes = @as([4]u8, @bitCast(@as(i32, -1)));
    const data = [_]u8{ 'l', size_bytes[0], size_bytes[1], size_bytes[2], size_bytes[3], 0x39, 0x30 };
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, -12345), obj.int.small);
}

test "BigInt multi-digit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // TYPE_LONG ('l') with size=2
    // value = digit[0] + digit[1] * 2^15
    // If digit[0] = 0x7FFF (32767) and digit[1] = 1
    // value = 32767 + 1 * 32768 = 65535
    const data = [_]u8{ 'l', 2, 0, 0, 0, 0xFF, 0x7F, 0x01, 0x00 };
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, 65535), obj.int.small);
}

test "BigInt large value stays as BigInt" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a number larger than i64 max
    // Using 5 digits of 0x7FFF each:
    // value = sum(0x7FFF * (2^15)^i for i in 0..4)
    // This is much larger than i64 max
    const data = [_]u8{
        'l', 6, 0, 0, 0, // size = 6 digits
        0xFF, 0x7F, // digit 0
        0xFF, 0x7F, // digit 1
        0xFF, 0x7F, // digit 2
        0xFF, 0x7F, // digit 3
        0xFF, 0x7F, // digit 4
        0xFF, 0x7F, // digit 5
    };
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.int, std.meta.activeTag(obj));
    // 6 * 15 = 90 bits, which fits in i128 but not i64, so still small after i128 conversion
    // Actually let's check: 6 digits at 15 bits = 90 bits magnitude
    // i64 has 63 bits magnitude, so this won't fit in i64 but fits in i128
    // Int.fromBigInt tries i64 first, fails, returns big
    try testing.expectEqual(Int.big, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(usize, 6), obj.int.big.digits.len);
}

test "BigInt toI64 conversion" {
    const testing = std.testing;

    // Test that a small BigInt converts to i64
    var big = BigInt{ .digits = &[_]u16{12345}, .negative = false };
    try testing.expectEqual(@as(?i64, 12345), big.toI64());

    // Test negative
    big.negative = true;
    try testing.expectEqual(@as(?i64, -12345), big.toI64());

    // Test zero
    big = BigInt{ .digits = &[_]u16{}, .negative = false };
    try testing.expectEqual(@as(?i64, 0), big.toI64());
}

test "BigInt toI128 conversion" {
    const testing = std.testing;

    // Test that values within i128 range convert correctly
    var big = BigInt{ .digits = &[_]u16{0x7FFF}, .negative = false };
    try testing.expectEqual(@as(?i128, 0x7FFF), big.toI128());

    // Test two digits: 0x7FFF + 0x7FFF * 2^15 = 0x7FFF + 0x3FFF8000 = 0x3FFFFFFF
    big = BigInt{ .digits = &[_]u16{ 0x7FFF, 0x7FFF }, .negative = false };
    const expected: i128 = 0x7FFF + @as(i128, 0x7FFF) * (1 << 15);
    try testing.expectEqual(@as(?i128, expected), big.toI128());
}

test "marshal TYPE_NONE" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const data = [_]u8{'N'};
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.none, obj);
}

test "marshal TYPE_TRUE and TYPE_FALSE" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const true_data = [_]u8{'T'};
    var reader = BufferReader{ .data = &true_data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);
    try testing.expectEqual(Object.true_val, obj);

    const false_data = [_]u8{'F'};
    reader = BufferReader{ .data = &false_data };
    var obj2 = try module.readAnyObject(&reader);
    defer obj2.deinit(allocator);
    try testing.expectEqual(Object.false_val, obj2);
}

test "marshal TYPE_ELLIPSIS" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const data = [_]u8{'.'};
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.ellipsis, obj);
}

test "marshal TYPE_STOPITER" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const data = [_]u8{'S'};
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.stop_iteration, obj);
}

test "marshal TYPE_INT" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const val_bytes = @as([4]u8, @bitCast(@as(i32, 42)));
    const data = [_]u8{'i'} ++ val_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, 42), obj.int.small);
}

test "marshal TYPE_INT64" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const val_bytes = @as([8]u8, @bitCast(@as(i64, 9223372036854775807)));
    const data = [_]u8{'I'} ++ val_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.int, std.meta.activeTag(obj));
    try testing.expectEqual(Int.small, std.meta.activeTag(obj.int));
    try testing.expectEqual(@as(i64, 9223372036854775807), obj.int.small);
}

test "marshal TYPE_BINARY_FLOAT" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const val: f64 = 3.14159;
    const val_bytes = @as([8]u8, @bitCast(val));
    const data = [_]u8{'g'} ++ val_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.float, std.meta.activeTag(obj));
    try testing.expectEqual(val, obj.float);
}

test "marshal TYPE_FLOAT text format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const str = "3.14159";
    const data = [_]u8{'f'} ++ [_]u8{str.len} ++ str.*;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.float, std.meta.activeTag(obj));
    try testing.expectApproxEqRel(@as(f64, 3.14159), obj.float, 0.00001);
}

test "marshal TYPE_BINARY_COMPLEX" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const real: f64 = 1.5;
    const imag: f64 = 2.5;
    const real_bytes = @as([8]u8, @bitCast(real));
    const imag_bytes = @as([8]u8, @bitCast(imag));
    const data = [_]u8{'y'} ++ real_bytes ++ imag_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.complex, std.meta.activeTag(obj));
    try testing.expectEqual(real, obj.complex.real);
    try testing.expectEqual(imag, obj.complex.imag);
}

test "marshal TYPE_STRING" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const str = "hello";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{'s'} ++ len_bytes ++ str.*;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("hello", obj.string);
}

test "marshal TYPE_ASCII" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const str = "world";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{'a'} ++ len_bytes ++ str.*;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("world", obj.string);
}

test "marshal TYPE_SHORT_ASCII" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const str = "abc";
    const data = [_]u8{ 'z', str.len } ++ str.*;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("abc", obj.string);
}

test "marshal TYPE_INTERNED" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const str = "interned";
    const len_bytes = @as([4]u8, @bitCast(@as(u32, str.len)));
    const data = [_]u8{'t'} ++ len_bytes ++ str.*;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("interned", obj.string);
    try testing.expectEqual(@as(usize, 1), module.interns.items.len);
    try testing.expectEqualStrings("interned", module.interns.items[0]);
}

test "marshal TYPE_STRINGREF" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 2;
    module.minor_ver = 7;

    const test_str = try allocator.dupe(u8, "cached");
    try module.interns.append(allocator, test_str);

    const idx_bytes = @as([4]u8, @bitCast(@as(u32, 0)));
    const data = [_]u8{'R'} ++ idx_bytes;
    var reader = BufferReader{ .data = &data };

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.string, std.meta.activeTag(obj));
    try testing.expectEqualStrings("cached", obj.string);
}

test "marshal TYPE_TUPLE" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const count_bytes = @as([4]u8, @bitCast(@as(u32, 2)));
    const val1_bytes = @as([4]u8, @bitCast(@as(i32, 10)));
    const val2_bytes = @as([4]u8, @bitCast(@as(i32, 20)));
    const data = [_]u8{'('} ++ count_bytes ++ [_]u8{'i'} ++ val1_bytes ++ [_]u8{'i'} ++ val2_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.tuple, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 2), obj.tuple.len);
    try testing.expectEqual(Object.int, std.meta.activeTag(obj.tuple[0]));
    try testing.expectEqual(@as(i64, 10), obj.tuple[0].int.small);
    try testing.expectEqual(@as(i64, 20), obj.tuple[1].int.small);
}

test "marshal TYPE_SMALL_TUPLE" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const data = [_]u8{ ')', 3, 'N', 'T', 'F' };
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.tuple, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 3), obj.tuple.len);
    try testing.expectEqual(Object.none, obj.tuple[0]);
    try testing.expectEqual(Object.true_val, obj.tuple[1]);
    try testing.expectEqual(Object.false_val, obj.tuple[2]);
}

test "marshal TYPE_LIST" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const count_bytes = @as([4]u8, @bitCast(@as(u32, 2)));
    const val1_bytes = @as([4]u8, @bitCast(@as(i32, 1)));
    const val2_bytes = @as([4]u8, @bitCast(@as(i32, 2)));
    const data = [_]u8{'['} ++ count_bytes ++ [_]u8{'i'} ++ val1_bytes ++ [_]u8{'i'} ++ val2_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.list, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 2), obj.list.len);
    try testing.expectEqual(@as(i64, 1), obj.list[0].int.small);
    try testing.expectEqual(@as(i64, 2), obj.list[1].int.small);
}

test "marshal TYPE_SET" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const count_bytes = @as([4]u8, @bitCast(@as(u32, 2)));
    const val1_bytes = @as([4]u8, @bitCast(@as(i32, 5)));
    const val2_bytes = @as([4]u8, @bitCast(@as(i32, 10)));
    const data = [_]u8{'<'} ++ count_bytes ++ [_]u8{'i'} ++ val1_bytes ++ [_]u8{'i'} ++ val2_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.set, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 2), obj.set.len);
}

test "marshal TYPE_FROZENSET" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const count_bytes = @as([4]u8, @bitCast(@as(u32, 1)));
    const val_bytes = @as([4]u8, @bitCast(@as(i32, 99)));
    const data = [_]u8{'>'} ++ count_bytes ++ [_]u8{'i'} ++ val_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.frozenset, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 1), obj.frozenset.len);
    try testing.expectEqual(@as(i64, 99), obj.frozenset[0].int.small);
}

test "marshal TYPE_DICT" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const str1 = "key1";
    const str2 = "key2";
    const len1 = @as([4]u8, @bitCast(@as(u32, str1.len)));
    const len2 = @as([4]u8, @bitCast(@as(u32, str2.len)));
    const val1 = @as([4]u8, @bitCast(@as(i32, 100)));
    const val2 = @as([4]u8, @bitCast(@as(i32, 200)));

    const data = [_]u8{'{'} ++
        [_]u8{'a'} ++ len1 ++ str1.* ++
        [_]u8{'i'} ++ val1 ++
        [_]u8{'a'} ++ len2 ++ str2.* ++
        [_]u8{'i'} ++ val2 ++
        [_]u8{'0'};
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(Object.dict, std.meta.activeTag(obj));
    try testing.expectEqual(@as(usize, 2), obj.dict.len);
    try testing.expectEqualStrings("key1", obj.dict[0].key.string);
    try testing.expectEqual(@as(i64, 100), obj.dict[0].value.int.small);
    try testing.expectEqualStrings("key2", obj.dict[1].key.string);
    try testing.expectEqual(@as(i64, 200), obj.dict[1].value.int.small);
}

test "marshal FLAG_REF with simple object" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const val_bytes = @as([4]u8, @bitCast(@as(i32, 42)));
    const data = [_]u8{'i' | 0x80} ++ val_bytes;
    var reader = BufferReader{ .data = &data };

    var module = Module.init(allocator);
    defer module.deinit();
    module.major_ver = 3;
    module.minor_ver = 11;

    var obj = try module.readAnyObject(&reader);
    defer obj.deinit(allocator);

    try testing.expectEqual(@as(i64, 42), obj.int.small);
    try testing.expectEqual(@as(usize, 1), module.refs.items.len);
    try testing.expectEqual(@as(i64, 42), module.refs.items[0].int.small);
}
