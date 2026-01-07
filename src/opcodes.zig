//! Python bytecode opcodes across all versions.
//!
//! Based on CPython's opcode definitions and pycdc's bytecode_ops.inl.
//! Each opcode is tagged with the Python version range where it exists.
//!
//! Note: Many opcodes were reassigned across Python versions. This module
//! currently uses Python 3.11+ opcode numbers as the primary mapping.
//! Version-specific decoding will be added later.

const std = @import("std");

/// Python version as major.minor
pub const Version = struct {
    major: u8,
    minor: u8,

    pub fn init(major: u8, minor: u8) Version {
        return .{ .major = major, .minor = minor };
    }

    pub fn compare(self: Version, other: Version) i32 {
        if (self.major != other.major) {
            return @as(i32, self.major) - @as(i32, other.major);
        }
        return @as(i32, self.minor) - @as(i32, other.minor);
    }

    pub fn gte(self: Version, major: u8, minor: u8) bool {
        return self.compare(Version.init(major, minor)) >= 0;
    }

    pub fn lte(self: Version, major: u8, minor: u8) bool {
        return self.compare(Version.init(major, minor)) <= 0;
    }

    pub fn between(self: Version, min_maj: u8, min_min: u8, max_maj: u8, max_min: u8) bool {
        return self.gte(min_maj, min_min) and self.lte(max_maj, max_min);
    }
};

/// Opcode enum - Python 3.11+ opcode values
/// For parsing older versions, use byteToOpcode() which handles version mapping.
pub const Opcode = enum(u16) {
    // No parameter opcodes (< 90)
    CACHE = 0,
    POP_TOP = 1,
    PUSH_NULL = 2,
    INTERPRETER_EXIT = 3,
    END_FOR = 4,
    END_SEND = 5,
    TO_BOOL = 6,
    NOP = 9,
    UNARY_NEGATIVE = 10,
    UNARY_NOT = 11,
    UNARY_INVERT = 12,
    RESERVED = 17,
    BINARY_SUBSCR = 25,
    BINARY_SLICE = 26,
    STORE_SLICE = 27,
    GET_LEN = 30,
    MATCH_MAPPING = 31,
    MATCH_SEQUENCE = 32,
    MATCH_KEYS = 33,
    PUSH_EXC_INFO = 35,
    CHECK_EXC_MATCH = 36,
    CHECK_EG_MATCH = 37,
    WITH_EXCEPT_START = 49,
    GET_AITER = 50,
    GET_ANEXT = 51,
    BEFORE_ASYNC_WITH = 52,
    BEFORE_WITH = 53,
    END_ASYNC_FOR = 54,
    CLEANUP_THROW = 55,
    STORE_SUBSCR = 60,
    DELETE_SUBSCR = 61,
    GET_ITER = 68,
    GET_YIELD_FROM_ITER = 69,
    LOAD_BUILD_CLASS = 71,
    LOAD_ASSERTION_ERROR = 74,
    RETURN_GENERATOR = 75,
    RETURN_VALUE = 83,
    SETUP_ANNOTATIONS = 85,
    LOAD_LOCALS = 87,
    POP_EXCEPT = 89,

    // Parameter opcodes (>= 90)
    // HAVE_ARGUMENT = 90, // Marker value, same as STORE_NAME
    STORE_NAME = 90,
    DELETE_NAME = 91,
    UNPACK_SEQUENCE = 92,
    FOR_ITER = 93,
    UNPACK_EX = 94,
    STORE_ATTR = 95,
    DELETE_ATTR = 96,
    STORE_GLOBAL = 97,
    DELETE_GLOBAL = 98,
    SWAP = 99,
    LOAD_CONST = 100,
    LOAD_NAME = 101,
    BUILD_TUPLE = 102,
    BUILD_LIST = 103,
    BUILD_SET = 104,
    BUILD_MAP = 105,
    LOAD_ATTR = 106,
    COMPARE_OP = 107,
    IMPORT_NAME = 108,
    IMPORT_FROM = 109,
    JUMP_FORWARD = 110,
    POP_JUMP_IF_FALSE = 114,
    POP_JUMP_IF_TRUE = 115,
    LOAD_GLOBAL = 116,
    IS_OP = 117,
    CONTAINS_OP = 118,
    RERAISE = 119,
    COPY = 120,
    RETURN_CONST = 121,
    BINARY_OP = 122,
    SEND = 123,
    LOAD_FAST = 124,
    STORE_FAST = 125,
    DELETE_FAST = 126,
    LOAD_FAST_CHECK = 127,
    POP_JUMP_IF_NOT_NONE = 128,
    POP_JUMP_IF_NONE = 129,
    RAISE_VARARGS = 130,
    GET_AWAITABLE = 131,
    MAKE_FUNCTION = 132,
    BUILD_SLICE = 133,
    JUMP_BACKWARD_NO_INTERRUPT = 134,
    MAKE_CELL = 135,
    LOAD_CLOSURE = 136,
    LOAD_DEREF = 137,
    STORE_DEREF = 138,
    DELETE_DEREF = 139,
    JUMP_BACKWARD = 140,
    LOAD_SUPER_ATTR = 141,
    CALL_FUNCTION_EX = 142,
    LOAD_FAST_AND_CLEAR = 143,
    EXTENDED_ARG = 144,
    LIST_APPEND = 145,
    SET_ADD = 146,
    MAP_ADD = 147,
    COPY_FREE_VARS = 149,
    YIELD_VALUE = 150,
    RESUME = 151,
    MATCH_CLASS = 152,
    BUILD_CONST_KEY_MAP = 156,
    BUILD_STRING = 157,
    CONVERT_VALUE = 162,
    LIST_EXTEND = 164,
    SET_UPDATE = 165,
    DICT_MERGE = 166,
    DICT_UPDATE = 167,
    LOAD_FAST_LOAD_FAST = 168,
    STORE_FAST_LOAD_FAST = 169,
    STORE_FAST_STORE_FAST = 170,
    CALL = 171,
    KW_NAMES = 172,
    CALL_INTRINSIC_1 = 173,
    CALL_INTRINSIC_2 = 174,
    LOAD_FROM_DICT_OR_GLOBALS = 175,
    LOAD_FROM_DICT_OR_DEREF = 176,
    SET_FUNCTION_ATTRIBUTE = 177,
    CALL_KW = 179,

    INVALID = 0xFFFF,

    const HAVE_ARGUMENT: u16 = 90;

    pub fn hasArg(self: Opcode) bool {
        return @intFromEnum(self) >= HAVE_ARGUMENT;
    }

    pub fn name(self: Opcode) []const u8 {
        return @tagName(self);
    }
};

/// Map raw bytecode value to opcode based on Python version.
/// Returns null for invalid/unknown opcodes.
pub fn byteToOpcode(_: Version, byte: u8) ?Opcode {
    // For now, use Python 3.11+ layout as default.
    // TODO: Add version-specific opcode tables
    return std.meta.intToEnum(Opcode, byte) catch return null;
}

/// Compare operation types (for COMPARE_OP)
pub const CompareOp = enum(u8) {
    LT = 0, // <
    LE = 1, // <=
    EQ = 2, // ==
    NE = 3, // !=
    GT = 4, // >
    GE = 5, // >=

    pub fn symbol(self: CompareOp) []const u8 {
        return switch (self) {
            .LT => "<",
            .LE => "<=",
            .EQ => "==",
            .NE => "!=",
            .GT => ">",
            .GE => ">=",
        };
    }
};

/// Binary operation types (for BINARY_OP in 3.11+)
pub const BinaryOp = enum(u8) {
    ADD = 0,
    AND = 1,
    FLOOR_DIVIDE = 2,
    LSHIFT = 3,
    MATRIX_MULTIPLY = 4,
    MULTIPLY = 5,
    REMAINDER = 6,
    OR = 7,
    POWER = 8,
    RSHIFT = 9,
    SUBTRACT = 10,
    TRUE_DIVIDE = 11,
    XOR = 12,
    INPLACE_ADD = 13,
    INPLACE_AND = 14,
    INPLACE_FLOOR_DIVIDE = 15,
    INPLACE_LSHIFT = 16,
    INPLACE_MATRIX_MULTIPLY = 17,
    INPLACE_MULTIPLY = 18,
    INPLACE_REMAINDER = 19,
    INPLACE_OR = 20,
    INPLACE_POWER = 21,
    INPLACE_RSHIFT = 22,
    INPLACE_SUBTRACT = 23,
    INPLACE_TRUE_DIVIDE = 24,
    INPLACE_XOR = 25,

    pub fn symbol(self: BinaryOp) []const u8 {
        return switch (self) {
            .ADD => "+",
            .AND => "&",
            .FLOOR_DIVIDE => "//",
            .LSHIFT => "<<",
            .MATRIX_MULTIPLY => "@",
            .MULTIPLY => "*",
            .REMAINDER => "%",
            .OR => "|",
            .POWER => "**",
            .RSHIFT => ">>",
            .SUBTRACT => "-",
            .TRUE_DIVIDE => "/",
            .XOR => "^",
            .INPLACE_ADD => "+=",
            .INPLACE_AND => "&=",
            .INPLACE_FLOOR_DIVIDE => "//=",
            .INPLACE_LSHIFT => "<<=",
            .INPLACE_MATRIX_MULTIPLY => "@=",
            .INPLACE_MULTIPLY => "*=",
            .INPLACE_REMAINDER => "%=",
            .INPLACE_OR => "|=",
            .INPLACE_POWER => "**=",
            .INPLACE_RSHIFT => ">>=",
            .INPLACE_SUBTRACT => "-=",
            .INPLACE_TRUE_DIVIDE => "/=",
            .INPLACE_XOR => "^=",
        };
    }
};

test "opcode has arg" {
    const testing = std.testing;
    try testing.expect(!Opcode.POP_TOP.hasArg());
    try testing.expect(!Opcode.RETURN_VALUE.hasArg());
    try testing.expect(Opcode.LOAD_CONST.hasArg());
    try testing.expect(Opcode.LOAD_FAST.hasArg());
    try testing.expect(Opcode.CALL.hasArg());
}

test "version comparison" {
    const testing = std.testing;
    const v311 = Version.init(3, 11);
    const v310 = Version.init(3, 10);
    const v27 = Version.init(2, 7);

    try testing.expect(v311.compare(v310) > 0);
    try testing.expect(v310.compare(v311) < 0);
    try testing.expect(v311.compare(v311) == 0);
    try testing.expect(v311.gte(3, 10));
    try testing.expect(v27.lte(3, 0));
    try testing.expect(v310.between(3, 0, 3, 12));
}
