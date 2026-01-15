//! Python bytecode opcodes across all versions.
//!
//! Based on CPython's opcode definitions and pycdc's bytecode_ops.inl.
//! Each opcode is tagged with the Python version range where it exists.
//!
//! This module provides version-specific opcode tables since Python
//! completely renumbered opcodes in 3.14 and made other changes across versions.

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

    pub fn lt(self: Version, major: u8, minor: u8) bool {
        return self.compare(Version.init(major, minor)) < 0;
    }

    pub fn between(self: Version, min_maj: u8, min_min: u8, max_maj: u8, max_min: u8) bool {
        return self.gte(min_maj, min_min) and self.lte(max_maj, max_min);
    }

    /// Get the HAVE_ARGUMENT threshold for this version.
    /// In Python 3.6+, all instructions are 2 bytes (word-based).
    /// In Python 3.14+, HAVE_ARGUMENT is 43.
    /// In Python 3.13, HAVE_ARGUMENT is 44 (renumbered opcodes).
    /// In Python 3.6-3.12, HAVE_ARGUMENT is 90.
    /// In Python < 3.6, HAVE_ARGUMENT is 90 but instructions vary in size.
    pub fn haveArgumentThreshold(self: Version) u16 {
        if (self.gte(3, 14)) return 43;
        if (self.gte(3, 13)) return 44;
        return 90;
    }
};

/// Canonical opcode names used internally.
/// The actual byte values vary by Python version - use byteToOpcode() for mapping.
pub const Opcode = enum(u16) {
    // Common opcodes across versions
    CACHE,
    POP_TOP,
    PUSH_NULL,
    INTERPRETER_EXIT,
    END_FOR,
    END_SEND,
    TO_BOOL,
    NOP,
    UNARY_NEGATIVE,
    UNARY_NOT,
    UNARY_INVERT,
    RESERVED,
    BINARY_SUBSCR,
    BINARY_SLICE,
    STORE_SLICE,
    GET_LEN,
    MATCH_MAPPING,
    MATCH_SEQUENCE,
    MATCH_KEYS,
    PUSH_EXC_INFO,
    CHECK_EXC_MATCH,
    JUMP_IF_NOT_EXC_MATCH,
    CHECK_EG_MATCH,
    WITH_EXCEPT_START,
    GET_AITER,
    GET_ANEXT,
    BEFORE_ASYNC_WITH,
    BEFORE_WITH,
    END_ASYNC_FOR,
    CLEANUP_THROW,
    STORE_SUBSCR,
    DELETE_SUBSCR,
    GET_ITER,
    GET_YIELD_FROM_ITER,
    YIELD_FROM,
    LOAD_BUILD_CLASS,
    LOAD_ASSERTION_ERROR,
    RETURN_GENERATOR,
    GEN_START,
    RETURN_VALUE,
    SETUP_ANNOTATIONS,
    LOAD_LOCALS,
    POP_EXCEPT,
    STORE_NAME,
    STORE_ANNOTATION,
    DELETE_NAME,
    UNPACK_SEQUENCE,
    FOR_ITER,
    UNPACK_EX,
    STORE_ATTR,
    DELETE_ATTR,
    STORE_GLOBAL,
    DELETE_GLOBAL,
    SWAP,
    LOAD_CONST,
    LOAD_NAME,
    BUILD_TUPLE,
    BUILD_TUPLE_UNPACK,
    BUILD_TUPLE_UNPACK_WITH_CALL,
    BUILD_LIST,
    BUILD_LIST_UNPACK,
    BUILD_SET,
    BUILD_SET_UNPACK,
    BUILD_MAP,
    BUILD_MAP_UNPACK,
    BUILD_MAP_UNPACK_WITH_CALL,
    LOAD_ATTR,
    COMPARE_OP,
    IMPORT_NAME,
    IMPORT_FROM,
    JUMP_FORWARD,
    POP_JUMP_IF_FALSE,
    POP_JUMP_IF_TRUE,
    POP_JUMP_FORWARD_IF_FALSE,
    POP_JUMP_FORWARD_IF_TRUE,
    POP_JUMP_BACKWARD_IF_FALSE,
    POP_JUMP_BACKWARD_IF_TRUE,
    LOAD_GLOBAL,
    IS_OP,
    CONTAINS_OP,
    RERAISE,
    COPY,
    RETURN_CONST,
    BINARY_OP,
    SEND,
    LOAD_FAST,
    STORE_FAST,
    DELETE_FAST,
    LOAD_FAST_CHECK,
    POP_JUMP_IF_NOT_NONE,
    POP_JUMP_IF_NONE,
    POP_JUMP_FORWARD_IF_NOT_NONE,
    POP_JUMP_FORWARD_IF_NONE,
    POP_JUMP_BACKWARD_IF_NOT_NONE,
    POP_JUMP_BACKWARD_IF_NONE,
    RAISE_VARARGS,
    GET_AWAITABLE,
    MAKE_FUNCTION,
    BUILD_SLICE,
    JUMP_BACKWARD_NO_INTERRUPT,
    MAKE_CELL,
    LOAD_CLOSURE,
    LOAD_DEREF,
    STORE_DEREF,
    DELETE_DEREF,
    JUMP_BACKWARD,
    LOAD_SUPER_ATTR,
    CALL_FUNCTION_EX,
    LOAD_FAST_AND_CLEAR,
    EXTENDED_ARG,
    LIST_APPEND,
    SET_ADD,
    MAP_ADD,
    COPY_FREE_VARS,
    YIELD_VALUE,
    RESUME,
    MATCH_CLASS,
    BUILD_CONST_KEY_MAP,
    BUILD_STRING,
    CONVERT_VALUE,
    LIST_EXTEND,
    LIST_TO_TUPLE,
    SET_UPDATE,
    DICT_MERGE,
    DICT_UPDATE,
    COPY_DICT_WITHOUT_KEYS,
    LOAD_FAST_LOAD_FAST,
    STORE_FAST_LOAD_FAST,
    STORE_FAST_STORE_FAST,
    CALL,
    KW_NAMES,
    CALL_INTRINSIC_1,
    CALL_INTRINSIC_2,
    LOAD_FROM_DICT_OR_GLOBALS,
    LOAD_FROM_DICT_OR_DEREF,
    SET_FUNCTION_ATTRIBUTE,
    CALL_KW,

    // Python 3.14+ new opcodes
    EXIT_INIT_CHECK,
    FORMAT_SIMPLE,
    FORMAT_WITH_SPEC,
    NOT_TAKEN,
    POP_ITER,
    BUILD_INTERPOLATION,
    BUILD_TEMPLATE,
    LOAD_COMMON_CONSTANT,
    LOAD_FAST_BORROW,
    LOAD_FAST_BORROW_LOAD_FAST_BORROW,
    LOAD_SMALL_INT,
    LOAD_SPECIAL,

    // Python 3.7-3.11 call setup
    LOAD_METHOD,
    CALL_METHOD,
    PRECALL,

    // f-string formatting (3.6-3.12, removed in 3.13)
    FORMAT_VALUE,

    // 3.13+ only
    ENTER_EXECUTOR,

    // Older version opcodes (3.11-3.13)
    BINARY_ADD,
    BINARY_SUBTRACT,
    BINARY_MULTIPLY,
    BINARY_TRUE_DIVIDE,
    BINARY_FLOOR_DIVIDE,
    BINARY_MODULO,
    BINARY_POWER,
    BINARY_MATRIX_MULTIPLY,
    BINARY_LSHIFT,
    BINARY_RSHIFT,
    BINARY_AND,
    BINARY_OR,
    BINARY_XOR,
    INPLACE_ADD,
    INPLACE_SUBTRACT,
    INPLACE_MULTIPLY,
    INPLACE_TRUE_DIVIDE,
    INPLACE_FLOOR_DIVIDE,
    INPLACE_MODULO,
    INPLACE_POWER,
    INPLACE_MATRIX_MULTIPLY,
    INPLACE_LSHIFT,
    INPLACE_RSHIFT,
    INPLACE_AND,
    INPLACE_OR,
    INPLACE_XOR,
    UNARY_POSITIVE,
    PRINT_EXPR,
    LOAD_CLASSDEREF,

    // Python 2.x specific opcodes (removed in 3.x)
    STOP_CODE,
    ROT_TWO,
    ROT_THREE,
    ROT_FOUR,
    ROT_N,
    DUP_TOP,
    DUP_TOP_TWO,
    UNARY_CONVERT,
    BINARY_DIVIDE,
    INPLACE_DIVIDE,
    SLICE_0,
    SLICE_1,
    SLICE_2,
    SLICE_3,
    STORE_SLICE_0,
    STORE_SLICE_1,
    STORE_SLICE_2,
    STORE_SLICE_3,
    DELETE_SLICE_0,
    DELETE_SLICE_1,
    DELETE_SLICE_2,
    DELETE_SLICE_3,
    STORE_MAP,
    PRINT_ITEM,
    PRINT_NEWLINE,
    PRINT_ITEM_TO,
    PRINT_NEWLINE_TO,
    BREAK_LOOP,
    WITH_CLEANUP,
    WITH_CLEANUP_START,
    WITH_CLEANUP_FINISH,
    IMPORT_STAR,
    EXEC_STMT,
    POP_BLOCK,
    END_FINALLY,
    BEGIN_FINALLY,
    CALL_FINALLY,
    POP_FINALLY,
    BUILD_CLASS,
    DUP_TOPX,
    JUMP_IF_FALSE, // Python 3.0 only (111) - differs from JUMP_IF_FALSE_OR_POP
    JUMP_IF_TRUE, // Python 3.0 only (112) - differs from JUMP_IF_TRUE_OR_POP
    JUMP_IF_FALSE_OR_POP,
    JUMP_IF_TRUE_OR_POP,
    STORE_LOCALS, // Python 3.0 only (69)
    JUMP_ABSOLUTE,
    CONTINUE_LOOP,
    SETUP_LOOP,
    SETUP_EXCEPT,
    SETUP_FINALLY,
    SETUP_ASYNC_WITH,
    CALL_FUNCTION,
    MAKE_CLOSURE,
    STORE_DEREF_OLD, // Python 2.x STORE_DEREF at 137
    CALL_FUNCTION_VAR,
    CALL_FUNCTION_KW,
    CALL_FUNCTION_VAR_KW,
    SETUP_WITH,
    SET_LINENO,

    INVALID,

    /// Check if this opcode takes an argument based on version.
    /// In Python 3.6+, all instructions are 2 bytes, but opcodes below
    /// HAVE_ARGUMENT have implicit arg of 0.
    pub fn hasArg(self: Opcode, ver: Version) bool {
        // Get the byte value for this opcode in this version
        const byte_val = opcodeToByteImpl(ver, self) orelse return false;
        return byte_val >= ver.haveArgumentThreshold();
    }

    pub fn name(self: Opcode) []const u8 {
        return @tagName(self);
    }
};

/// Python 3.14 opcode byte values
const opcode_table_3_14 = [_]?Opcode{
    .CACHE, // 0
    .BINARY_SLICE, // 1
    .BUILD_TEMPLATE, // 2
    null, // 3 (gap)
    .CALL_FUNCTION_EX, // 4
    .CHECK_EG_MATCH, // 5
    .CHECK_EXC_MATCH, // 6
    .CLEANUP_THROW, // 7
    .DELETE_SUBSCR, // 8
    .END_FOR, // 9
    .END_SEND, // 10
    .EXIT_INIT_CHECK, // 11
    .FORMAT_SIMPLE, // 12
    .FORMAT_WITH_SPEC, // 13
    .GET_AITER, // 14
    .GET_ANEXT, // 15
    .GET_ITER, // 16
    .RESERVED, // 17
    .GET_LEN, // 18
    .GET_YIELD_FROM_ITER, // 19
    .INTERPRETER_EXIT, // 20
    .LOAD_BUILD_CLASS, // 21
    .LOAD_LOCALS, // 22
    .MAKE_FUNCTION, // 23
    .MATCH_KEYS, // 24
    .MATCH_MAPPING, // 25
    .MATCH_SEQUENCE, // 26
    .NOP, // 27
    .NOT_TAKEN, // 28
    .POP_EXCEPT, // 29
    .POP_ITER, // 30
    .POP_TOP, // 31
    .PUSH_EXC_INFO, // 32
    .PUSH_NULL, // 33
    .RETURN_GENERATOR, // 34
    .RETURN_VALUE, // 35
    .SETUP_ANNOTATIONS, // 36
    .STORE_SLICE, // 37
    .STORE_SUBSCR, // 38
    .TO_BOOL, // 39
    .UNARY_INVERT, // 40
    .UNARY_NEGATIVE, // 41
    .UNARY_NOT, // 42
    .WITH_EXCEPT_START, // 43 (HAVE_ARGUMENT threshold)
    .BINARY_OP, // 44
    .BUILD_INTERPOLATION, // 45
    .BUILD_LIST, // 46
    .BUILD_MAP, // 47
    .BUILD_SET, // 48
    .BUILD_SLICE, // 49
    .BUILD_STRING, // 50
    .BUILD_TUPLE, // 51
    .CALL, // 52
    .CALL_INTRINSIC_1, // 53
    .CALL_INTRINSIC_2, // 54
    .CALL_KW, // 55
    .COMPARE_OP, // 56
    .CONTAINS_OP, // 57
    .CONVERT_VALUE, // 58
    .COPY, // 59
    .COPY_FREE_VARS, // 60
    .DELETE_ATTR, // 61
    .DELETE_DEREF, // 62
    .DELETE_FAST, // 63
    .DELETE_GLOBAL, // 64
    .DELETE_NAME, // 65
    .DICT_MERGE, // 66
    .DICT_UPDATE, // 67
    .END_ASYNC_FOR, // 68
    .EXTENDED_ARG, // 69
    .FOR_ITER, // 70
    .GET_AWAITABLE, // 71
    .IMPORT_FROM, // 72
    .IMPORT_NAME, // 73
    .IS_OP, // 74
    .JUMP_BACKWARD, // 75
    .JUMP_BACKWARD_NO_INTERRUPT, // 76
    .JUMP_FORWARD, // 77
    .LIST_APPEND, // 78
    .LIST_EXTEND, // 79
    .LOAD_ATTR, // 80
    .LOAD_COMMON_CONSTANT, // 81
    .LOAD_CONST, // 82
    .LOAD_DEREF, // 83
    .LOAD_FAST, // 84
    .LOAD_FAST_AND_CLEAR, // 85
    .LOAD_FAST_BORROW, // 86
    .LOAD_FAST_BORROW_LOAD_FAST_BORROW, // 87
    .LOAD_FAST_CHECK, // 88
    .LOAD_FAST_LOAD_FAST, // 89
    .LOAD_FROM_DICT_OR_DEREF, // 90
    .LOAD_FROM_DICT_OR_GLOBALS, // 91
    .LOAD_GLOBAL, // 92
    .LOAD_NAME, // 93
    .LOAD_SMALL_INT, // 94
    .LOAD_SPECIAL, // 95
    .LOAD_SUPER_ATTR, // 96
    .MAKE_CELL, // 97
    .MAP_ADD, // 98
    .MATCH_CLASS, // 99
    .POP_JUMP_IF_FALSE, // 100
    .POP_JUMP_IF_NONE, // 101
    .POP_JUMP_IF_NOT_NONE, // 102
    .POP_JUMP_IF_TRUE, // 103
    .RAISE_VARARGS, // 104
    .RERAISE, // 105
    .SEND, // 106
    .SET_ADD, // 107
    .SET_FUNCTION_ATTRIBUTE, // 108
    .SET_UPDATE, // 109
    .STORE_ATTR, // 110
    .STORE_DEREF, // 111
    .STORE_FAST, // 112
    .STORE_FAST_LOAD_FAST, // 113
    .STORE_FAST_STORE_FAST, // 114
    .STORE_GLOBAL, // 115
    .STORE_NAME, // 116
    .SWAP, // 117
    .UNPACK_EX, // 118
    .UNPACK_SEQUENCE, // 119
    .YIELD_VALUE, // 120
    null, // 121
    null, // 122
    null, // 123
    null, // 124
    null, // 125
    null, // 126
    null, // 127
    .RESUME, // 128
};

/// Python 3.11 opcode byte values (different from 3.12+!)
const opcode_table_3_11 = [_]?Opcode{
    .CACHE, // 0
    .POP_TOP, // 1
    .PUSH_NULL, // 2
    null, // 3
    null, // 4
    null, // 5
    null, // 6
    null, // 7
    null, // 8
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13
    null, // 14
    .UNARY_INVERT, // 15
    null, // 16
    null, // 17
    null, // 18
    null, // 19
    null, // 20
    null, // 21
    null, // 22
    null, // 23
    null, // 24
    .BINARY_SUBSCR, // 25
    null, // 26
    null, // 27
    null, // 28
    null, // 29
    .GET_LEN, // 30
    .MATCH_MAPPING, // 31
    .MATCH_SEQUENCE, // 32
    .MATCH_KEYS, // 33
    null, // 34
    .PUSH_EXC_INFO, // 35
    .CHECK_EXC_MATCH, // 36
    .CHECK_EG_MATCH, // 37
    null, // 38
    null, // 39
    null, // 40
    null, // 41
    null, // 42
    null, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    .WITH_EXCEPT_START, // 49
    .GET_AITER, // 50
    .GET_ANEXT, // 51
    .BEFORE_ASYNC_WITH, // 52
    .BEFORE_WITH, // 53
    .END_ASYNC_FOR, // 54
    null, // 55
    null, // 56
    null, // 57
    null, // 58
    null, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    null, // 62
    null, // 63
    null, // 64
    null, // 65
    null, // 66
    null, // 67
    .GET_ITER, // 68
    .GET_YIELD_FROM_ITER, // 69
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    null, // 72
    null, // 73
    .LOAD_ASSERTION_ERROR, // 74
    .RETURN_GENERATOR, // 75
    null, // 76
    null, // 77
    null, // 78
    null, // 79
    null, // 80
    null, // 81
    null, // 82
    .RETURN_VALUE, // 83
    null, // 84
    .SETUP_ANNOTATIONS, // 85
    .YIELD_VALUE, // 86
    null, // 87
    null, // 88
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90 (HAVE_ARGUMENT)
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    .SWAP, // 99
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    null, // 111 - JUMP_IF_FALSE_OR_POP (removed)
    null, // 112 - JUMP_IF_TRUE_OR_POP (removed)
    null, // 113
    .POP_JUMP_FORWARD_IF_FALSE, // 114
    .POP_JUMP_FORWARD_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    .IS_OP, // 117
    .CONTAINS_OP, // 118
    .RERAISE, // 119
    .COPY, // 120
    null, // 121
    .BINARY_OP, // 122
    .SEND, // 123
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    null, // 127
    .POP_JUMP_FORWARD_IF_NOT_NONE, // 128
    .POP_JUMP_FORWARD_IF_NONE, // 129
    .RAISE_VARARGS, // 130
    .GET_AWAITABLE, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    .JUMP_BACKWARD_NO_INTERRUPT, // 134
    .MAKE_CELL, // 135
    .LOAD_CLOSURE, // 136
    .LOAD_DEREF, // 137
    .STORE_DEREF, // 138
    .DELETE_DEREF, // 139
    .JUMP_BACKWARD, // 140
    null, // 141
    .CALL_FUNCTION_EX, // 142
    null, // 143
    .EXTENDED_ARG, // 144
    .LIST_APPEND, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
    .LOAD_CLASSDEREF, // 148
    .COPY_FREE_VARS, // 149
    null, // 150
    .RESUME, // 151
    .MATCH_CLASS, // 152
    null, // 153
    null, // 154
    .FORMAT_VALUE, // 155
    .BUILD_CONST_KEY_MAP, // 156
    .BUILD_STRING, // 157
    null, // 158
    null, // 159
    .LOAD_METHOD, // 160
    null, // 161
    .LIST_EXTEND, // 162
    .SET_UPDATE, // 163
    .DICT_MERGE, // 164
    .DICT_UPDATE, // 165
    .PRECALL, // 166
    null, // 167
    null, // 168
    null, // 169
    null, // 170
    .CALL, // 171
    .KW_NAMES, // 172
    .POP_JUMP_BACKWARD_IF_NOT_NONE, // 173
    .POP_JUMP_BACKWARD_IF_NONE, // 174
    .POP_JUMP_BACKWARD_IF_FALSE, // 175
    .POP_JUMP_BACKWARD_IF_TRUE, // 176
};

/// Python 3.12-3.13 opcode byte values
const opcode_table_3_12 = [_]?Opcode{
    .CACHE, // 0
    .POP_TOP, // 1
    .PUSH_NULL, // 2
    .INTERPRETER_EXIT, // 3
    .END_FOR, // 4
    .END_SEND, // 5
    null, // 6
    null, // 7
    null, // 8
    .NOP, // 9
    null, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13
    null, // 14
    .UNARY_INVERT, // 15
    null, // 16
    .RESERVED, // 17
    null, // 18
    null, // 19
    null, // 20
    null, // 21
    null, // 22
    null, // 23
    null, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_SLICE, // 26
    .STORE_SLICE, // 27
    null, // 28
    null, // 29
    .GET_LEN, // 30
    .MATCH_MAPPING, // 31
    .MATCH_SEQUENCE, // 32
    .MATCH_KEYS, // 33
    null, // 34
    .PUSH_EXC_INFO, // 35
    .CHECK_EXC_MATCH, // 36
    .CHECK_EG_MATCH, // 37
    null, // 38
    null, // 39
    null, // 40
    null, // 41
    null, // 42
    null, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    .WITH_EXCEPT_START, // 49
    .GET_AITER, // 50
    .GET_ANEXT, // 51
    .BEFORE_ASYNC_WITH, // 52
    .BEFORE_WITH, // 53
    .END_ASYNC_FOR, // 54
    .CLEANUP_THROW, // 55
    null, // 56
    null, // 57
    null, // 58
    null, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    null, // 62
    null, // 63
    null, // 64
    null, // 65
    null, // 66
    null, // 67
    .GET_ITER, // 68
    .GET_YIELD_FROM_ITER, // 69
    null, // 70
    .LOAD_BUILD_CLASS, // 71
    null, // 72
    null, // 73
    .LOAD_ASSERTION_ERROR, // 74
    .RETURN_GENERATOR, // 75
    null, // 76
    null, // 77
    null, // 78
    null, // 79
    null, // 80
    null, // 81
    null, // 82
    .RETURN_VALUE, // 83
    null, // 84
    .SETUP_ANNOTATIONS, // 85
    null, // 86
    .LOAD_LOCALS, // 87
    null, // 88
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90 (HAVE_ARGUMENT)
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    .SWAP, // 99
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    null, // 111
    null, // 112
    null, // 113
    .POP_JUMP_IF_FALSE, // 114
    .POP_JUMP_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    .IS_OP, // 117
    .CONTAINS_OP, // 118
    .RERAISE, // 119
    .COPY, // 120
    .RETURN_CONST, // 121
    .BINARY_OP, // 122
    .SEND, // 123
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    .LOAD_FAST_CHECK, // 127
    .POP_JUMP_IF_NOT_NONE, // 128
    .POP_JUMP_IF_NONE, // 129
    .RAISE_VARARGS, // 130
    .GET_AWAITABLE, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    .JUMP_BACKWARD_NO_INTERRUPT, // 134
    .MAKE_CELL, // 135
    .LOAD_CLOSURE, // 136
    .LOAD_DEREF, // 137
    .STORE_DEREF, // 138
    .DELETE_DEREF, // 139
    .JUMP_BACKWARD, // 140
    .LOAD_SUPER_ATTR, // 141
    .CALL_FUNCTION_EX, // 142
    .LOAD_FAST_AND_CLEAR, // 143
    .EXTENDED_ARG, // 144
    .LIST_APPEND, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
    null, // 148
    .COPY_FREE_VARS, // 149
    .YIELD_VALUE, // 150
    .RESUME, // 151
    .MATCH_CLASS, // 152
    null, // 153
    null, // 154
    .FORMAT_VALUE, // 155
    .BUILD_CONST_KEY_MAP, // 156
    .BUILD_STRING, // 157
    null, // 158
    null, // 159
    null, // 160
    null, // 161
    .LIST_EXTEND, // 162
    .SET_UPDATE, // 163
    .DICT_MERGE, // 164
    .DICT_UPDATE, // 165
    null, // 166
    null, // 167
    null, // 168
    null, // 169
    null, // 170
    .CALL, // 171
    .KW_NAMES, // 172
    .CALL_INTRINSIC_1, // 173
    .CALL_INTRINSIC_2, // 174
    .LOAD_FROM_DICT_OR_GLOBALS, // 175
    .LOAD_FROM_DICT_OR_DEREF, // 176
};

/// Python 3.13 opcode byte values (completely renumbered from 3.12!)
const opcode_table_3_13 = [_]?Opcode{
    .CACHE, // 0
    .BEFORE_ASYNC_WITH, // 1
    .BEFORE_WITH, // 2
    null, // 3 (gap)
    .BINARY_SLICE, // 4
    .BINARY_SUBSCR, // 5
    .CHECK_EG_MATCH, // 6
    .CHECK_EXC_MATCH, // 7
    .CLEANUP_THROW, // 8
    .DELETE_SUBSCR, // 9
    .END_ASYNC_FOR, // 10
    .END_FOR, // 11
    .END_SEND, // 12
    .EXIT_INIT_CHECK, // 13
    .FORMAT_SIMPLE, // 14
    .FORMAT_WITH_SPEC, // 15
    .GET_AITER, // 16
    .RESERVED, // 17
    .GET_ANEXT, // 18
    .GET_ITER, // 19
    .GET_LEN, // 20
    .GET_YIELD_FROM_ITER, // 21
    .INTERPRETER_EXIT, // 22
    .LOAD_ASSERTION_ERROR, // 23
    .LOAD_BUILD_CLASS, // 24
    .LOAD_LOCALS, // 25
    .MAKE_FUNCTION, // 26
    .MATCH_KEYS, // 27
    .MATCH_MAPPING, // 28
    .MATCH_SEQUENCE, // 29
    .NOP, // 30
    .POP_EXCEPT, // 31
    .POP_TOP, // 32
    .PUSH_EXC_INFO, // 33
    .PUSH_NULL, // 34
    .RETURN_GENERATOR, // 35
    .RETURN_VALUE, // 36
    .SETUP_ANNOTATIONS, // 37
    .STORE_SLICE, // 38
    .STORE_SUBSCR, // 39
    .TO_BOOL, // 40
    .UNARY_INVERT, // 41
    .UNARY_NEGATIVE, // 42
    .UNARY_NOT, // 43
    .WITH_EXCEPT_START, // 44
    .BINARY_OP, // 45 (HAVE_ARGUMENT threshold)
    .BUILD_CONST_KEY_MAP, // 46
    .BUILD_LIST, // 47
    .BUILD_MAP, // 48
    .BUILD_SET, // 49
    .BUILD_SLICE, // 50
    .BUILD_STRING, // 51
    .BUILD_TUPLE, // 52
    .CALL, // 53
    .CALL_FUNCTION_EX, // 54
    .CALL_INTRINSIC_1, // 55
    .CALL_INTRINSIC_2, // 56
    .CALL_KW, // 57
    .COMPARE_OP, // 58
    .CONTAINS_OP, // 59
    .CONVERT_VALUE, // 60
    .COPY, // 61
    .COPY_FREE_VARS, // 62
    .DELETE_ATTR, // 63
    .DELETE_DEREF, // 64
    .DELETE_FAST, // 65
    .DELETE_GLOBAL, // 66
    .DELETE_NAME, // 67
    .DICT_MERGE, // 68
    .DICT_UPDATE, // 69
    .ENTER_EXECUTOR, // 70
    .EXTENDED_ARG, // 71
    .FOR_ITER, // 72
    .GET_AWAITABLE, // 73
    .IMPORT_FROM, // 74
    .IMPORT_NAME, // 75
    .IS_OP, // 76
    .JUMP_BACKWARD, // 77
    .JUMP_BACKWARD_NO_INTERRUPT, // 78
    .JUMP_FORWARD, // 79
    .LIST_APPEND, // 80
    .LIST_EXTEND, // 81
    .LOAD_ATTR, // 82
    .LOAD_CONST, // 83
    .LOAD_DEREF, // 84
    .LOAD_FAST, // 85
    .LOAD_FAST_AND_CLEAR, // 86
    .LOAD_FAST_CHECK, // 87
    .LOAD_FAST_LOAD_FAST, // 88
    .LOAD_FROM_DICT_OR_DEREF, // 89
    .LOAD_FROM_DICT_OR_GLOBALS, // 90
    .LOAD_GLOBAL, // 91
    .LOAD_NAME, // 92
    .LOAD_SUPER_ATTR, // 93
    .MAKE_CELL, // 94
    .MAP_ADD, // 95
    .MATCH_CLASS, // 96
    .POP_JUMP_IF_FALSE, // 97
    .POP_JUMP_IF_NONE, // 98
    .POP_JUMP_IF_NOT_NONE, // 99
    .POP_JUMP_IF_TRUE, // 100
    .RAISE_VARARGS, // 101
    .RERAISE, // 102
    .RETURN_CONST, // 103
    .SEND, // 104
    .SET_ADD, // 105
    .SET_FUNCTION_ATTRIBUTE, // 106
    .SET_UPDATE, // 107
    .STORE_ATTR, // 108
    .STORE_DEREF, // 109
    .STORE_FAST, // 110
    .STORE_FAST_LOAD_FAST, // 111
    .STORE_FAST_STORE_FAST, // 112
    .STORE_GLOBAL, // 113
    .STORE_NAME, // 114
    .SWAP, // 115
    .UNPACK_EX, // 116
    .UNPACK_SEQUENCE, // 117
    .YIELD_VALUE, // 118
    null, // 119-148 gap
    null, // 120
    null, // 121
    null, // 122
    null, // 123
    null, // 124
    null, // 125
    null, // 126
    null, // 127
    null, // 128
    null, // 129
    null, // 130
    null, // 131
    null, // 132
    null, // 133
    null, // 134
    null, // 135
    null, // 136
    null, // 137
    null, // 138
    null, // 139
    null, // 140
    null, // 141
    null, // 142
    null, // 143
    null, // 144
    null, // 145
    null, // 146
    null, // 147
    null, // 148
    .RESUME, // 149
};

/// Python 3.10 opcode byte values
const opcode_table_3_10 = [_]?Opcode{
    null, // 0 - <0>
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .DUP_TOP_TWO, // 5
    .ROT_FOUR, // 6
    null, // 7 - <7>
    null, // 8 - <8>
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13 - <13>
    null, // 14 - <14>
    .UNARY_INVERT, // 15
    .BINARY_MATRIX_MULTIPLY, // 16
    .INPLACE_MATRIX_MULTIPLY, // 17
    null, // 18 - <18>
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    null, // 21 - <21>
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    .GET_LEN, // 30
    .MATCH_MAPPING, // 31
    .MATCH_SEQUENCE, // 32
    .MATCH_KEYS, // 33
    .COPY_DICT_WITHOUT_KEYS, // 34
    null, // 35 - <35>
    null, // 36 - <36>
    null, // 37 - <37>
    null, // 38 - <38>
    null, // 39 - <39>
    null, // 40 - <40>
    null, // 41 - <41>
    null, // 42 - <42>
    null, // 43 - <43>
    null, // 44 - <44>
    null, // 45 - <45>
    null, // 46 - <46>
    null, // 47 - <47>
    null, // 48 - <48>
    .WITH_EXCEPT_START, // 49
    .GET_AITER, // 50
    .GET_ANEXT, // 51
    .BEFORE_ASYNC_WITH, // 52
    null, // 53 - <53>
    .END_ASYNC_FOR, // 54
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    null, // 58 - <58>
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    .GET_YIELD_FROM_ITER, // 69
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    .YIELD_FROM, // 72
    .GET_AWAITABLE, // 73
    .LOAD_ASSERTION_ERROR, // 74
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    null, // 80 - <80>
    null, // 81 - <81>
    .LIST_TO_TUPLE, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    .SETUP_ANNOTATIONS, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    null, // 88 - <88>
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    .ROT_N, // 99
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE_OR_POP, // 111
    .JUMP_IF_TRUE_OR_POP, // 112
    .JUMP_ABSOLUTE, // 113
    .POP_JUMP_IF_FALSE, // 114
    .POP_JUMP_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    .IS_OP, // 117
    .CONTAINS_OP, // 118
    .RERAISE, // 119
    null, // 120 - <120>
    .JUMP_IF_NOT_EXC_MATCH, // 121
    .SETUP_FINALLY, // 122
    null, // 123 - <123>
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    null, // 127 - <127>
    null, // 128 - <128>
    .GEN_START, // 129
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    null, // 134 - <134>
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    .DELETE_DEREF, // 138
    null, // 139 - <139>
    null, // 140 - <140>
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_EX, // 142
    .SETUP_WITH, // 143
    .EXTENDED_ARG, // 144
    .LIST_APPEND, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
    .LOAD_CLASSDEREF, // 148
    null, // 149 - <149>
    null, // 150 - <150>
    null, // 151 - <151>
    .MATCH_CLASS, // 152
    null, // 153 - <153>
    .SETUP_ASYNC_WITH, // 154
    .FORMAT_VALUE, // 155
    .BUILD_CONST_KEY_MAP, // 156
    .BUILD_STRING, // 157
    null, // 158 - <158>
    null, // 159 - <159>
    .LOAD_METHOD, // 160
    .CALL_METHOD, // 161
    .LIST_EXTEND, // 162
    .SET_UPDATE, // 163
    .DICT_MERGE, // 164
    .DICT_UPDATE, // 165
    null, // 166 - <166>
    null, // 167 - <167>
    null, // 168 - <168>
    null, // 169 - <169>
    null, // 170 - <170>
    null, // 171 - <171>
    null, // 172 - <172>
    null, // 173 - <173>
    null, // 174 - <174>
    null, // 175 - <175>
    null, // 176 - <176>
    null, // 177 - <177>
    null, // 178 - <178>
    null, // 179 - <179>
    null, // 180 - <180>
    null, // 181 - <181>
    null, // 182 - <182>
    null, // 183 - <183>
    null, // 184 - <184>
    null, // 185 - <185>
    null, // 186 - <186>
    null, // 187 - <187>
    null, // 188 - <188>
    null, // 189 - <189>
    null, // 190 - <190>
    null, // 191 - <191>
    null, // 192 - <192>
    null, // 193 - <193>
    null, // 194 - <194>
    null, // 195 - <195>
    null, // 196 - <196>
    null, // 197 - <197>
    null, // 198 - <198>
    null, // 199 - <199>
    null, // 200 - <200>
    null, // 201 - <201>
    null, // 202 - <202>
    null, // 203 - <203>
    null, // 204 - <204>
    null, // 205 - <205>
    null, // 206 - <206>
    null, // 207 - <207>
    null, // 208 - <208>
    null, // 209 - <209>
    null, // 210 - <210>
    null, // 211 - <211>
    null, // 212 - <212>
    null, // 213 - <213>
    null, // 214 - <214>
    null, // 215 - <215>
    null, // 216 - <216>
    null, // 217 - <217>
    null, // 218 - <218>
    null, // 219 - <219>
    null, // 220 - <220>
    null, // 221 - <221>
    null, // 222 - <222>
    null, // 223 - <223>
    null, // 224 - <224>
    null, // 225 - <225>
    null, // 226 - <226>
    null, // 227 - <227>
    null, // 228 - <228>
    null, // 229 - <229>
    null, // 230 - <230>
    null, // 231 - <231>
    null, // 232 - <232>
    null, // 233 - <233>
    null, // 234 - <234>
    null, // 235 - <235>
    null, // 236 - <236>
    null, // 237 - <237>
    null, // 238 - <238>
    null, // 239 - <239>
    null, // 240 - <240>
    null, // 241 - <241>
    null, // 242 - <242>
    null, // 243 - <243>
    null, // 244 - <244>
    null, // 245 - <245>
    null, // 246 - <246>
    null, // 247 - <247>
    null, // 248 - <248>
    null, // 249 - <249>
    null, // 250 - <250>
    null, // 251 - <251>
    null, // 252 - <252>
    null, // 253 - <253>
    null, // 254 - <254>
    null, // 255 - <255>
};

/// Python 3.9 opcode byte values
const opcode_table_3_9 = [_]?Opcode{
    null, // 0 - <0>
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .DUP_TOP_TWO, // 5
    .ROT_FOUR, // 6
    null, // 7 - <7>
    null, // 8 - <8>
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13 - <13>
    null, // 14 - <14>
    .UNARY_INVERT, // 15
    .BINARY_MATRIX_MULTIPLY, // 16
    .INPLACE_MATRIX_MULTIPLY, // 17
    null, // 18 - <18>
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    null, // 21 - <21>
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    null, // 30 - <30>
    null, // 31 - <31>
    null, // 32 - <32>
    null, // 33 - <33>
    null, // 34 - <34>
    null, // 35 - <35>
    null, // 36 - <36>
    null, // 37 - <37>
    null, // 38 - <38>
    null, // 39 - <39>
    null, // 40 - <40>
    null, // 41 - <41>
    null, // 42 - <42>
    null, // 43 - <43>
    null, // 44 - <44>
    null, // 45 - <45>
    null, // 46 - <46>
    null, // 47 - <47>
    .RERAISE, // 48
    .WITH_EXCEPT_START, // 49
    .GET_AITER, // 50
    .GET_ANEXT, // 51
    .BEFORE_ASYNC_WITH, // 52
    null, // 53 - <53>
    .END_ASYNC_FOR, // 54
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    null, // 58 - <58>
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    .GET_YIELD_FROM_ITER, // 69
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    .YIELD_FROM, // 72
    .GET_AWAITABLE, // 73
    .LOAD_ASSERTION_ERROR, // 74
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    null, // 80 - <80>
    null, // 81 - <81>
    .LIST_TO_TUPLE, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    .SETUP_ANNOTATIONS, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    null, // 88 - <88>
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    null, // 99 - <99>
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE_OR_POP, // 111
    .JUMP_IF_TRUE_OR_POP, // 112
    .JUMP_ABSOLUTE, // 113
    .POP_JUMP_IF_FALSE, // 114
    .POP_JUMP_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    .IS_OP, // 117
    .CONTAINS_OP, // 118
    null, // 119 - <119>
    null, // 120 - <120>
    .JUMP_IF_NOT_EXC_MATCH, // 121
    .SETUP_FINALLY, // 122
    null, // 123 - <123>
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    null, // 127 - <127>
    null, // 128 - <128>
    null, // 129 - <129>
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    null, // 134 - <134>
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    .DELETE_DEREF, // 138
    null, // 139 - <139>
    null, // 140 - <140>
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_EX, // 142
    .SETUP_WITH, // 143
    .EXTENDED_ARG, // 144
    .LIST_APPEND, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
    .LOAD_CLASSDEREF, // 148
    null, // 149 - <149>
    null, // 150 - <150>
    null, // 151 - <151>
    null, // 152 - <152>
    null, // 153 - <153>
    .SETUP_ASYNC_WITH, // 154
    .FORMAT_VALUE, // 155
    .BUILD_CONST_KEY_MAP, // 156
    .BUILD_STRING, // 157
    null, // 158 - <158>
    null, // 159 - <159>
    .LOAD_METHOD, // 160
    .CALL_METHOD, // 161
    .LIST_EXTEND, // 162
    .SET_UPDATE, // 163
    .DICT_MERGE, // 164
    .DICT_UPDATE, // 165
    null, // 166 - <166>
    null, // 167 - <167>
    null, // 168 - <168>
    null, // 169 - <169>
    null, // 170 - <170>
    null, // 171 - <171>
    null, // 172 - <172>
    null, // 173 - <173>
    null, // 174 - <174>
    null, // 175 - <175>
    null, // 176 - <176>
    null, // 177 - <177>
    null, // 178 - <178>
    null, // 179 - <179>
    null, // 180 - <180>
    null, // 181 - <181>
    null, // 182 - <182>
    null, // 183 - <183>
    null, // 184 - <184>
    null, // 185 - <185>
    null, // 186 - <186>
    null, // 187 - <187>
    null, // 188 - <188>
    null, // 189 - <189>
    null, // 190 - <190>
    null, // 191 - <191>
    null, // 192 - <192>
    null, // 193 - <193>
    null, // 194 - <194>
    null, // 195 - <195>
    null, // 196 - <196>
    null, // 197 - <197>
    null, // 198 - <198>
    null, // 199 - <199>
    null, // 200 - <200>
    null, // 201 - <201>
    null, // 202 - <202>
    null, // 203 - <203>
    null, // 204 - <204>
    null, // 205 - <205>
    null, // 206 - <206>
    null, // 207 - <207>
    null, // 208 - <208>
    null, // 209 - <209>
    null, // 210 - <210>
    null, // 211 - <211>
    null, // 212 - <212>
    null, // 213 - <213>
    null, // 214 - <214>
    null, // 215 - <215>
    null, // 216 - <216>
    null, // 217 - <217>
    null, // 218 - <218>
    null, // 219 - <219>
    null, // 220 - <220>
    null, // 221 - <221>
    null, // 222 - <222>
    null, // 223 - <223>
    null, // 224 - <224>
    null, // 225 - <225>
    null, // 226 - <226>
    null, // 227 - <227>
    null, // 228 - <228>
    null, // 229 - <229>
    null, // 230 - <230>
    null, // 231 - <231>
    null, // 232 - <232>
    null, // 233 - <233>
    null, // 234 - <234>
    null, // 235 - <235>
    null, // 236 - <236>
    null, // 237 - <237>
    null, // 238 - <238>
    null, // 239 - <239>
    null, // 240 - <240>
    null, // 241 - <241>
    null, // 242 - <242>
    null, // 243 - <243>
    null, // 244 - <244>
    null, // 245 - <245>
    null, // 246 - <246>
    null, // 247 - <247>
    null, // 248 - <248>
    null, // 249 - <249>
    null, // 250 - <250>
    null, // 251 - <251>
    null, // 252 - <252>
    null, // 253 - <253>
    null, // 254 - <254>
    null, // 255 - <255>
};

/// Python 3.8 opcode byte values
const opcode_table_3_8 = [_]?Opcode{
    null, // 0 - <0>
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .DUP_TOP_TWO, // 5
    .ROT_FOUR, // 6
    null, // 7 - <7>
    null, // 8 - <8>
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13 - <13>
    null, // 14 - <14>
    .UNARY_INVERT, // 15
    .BINARY_MATRIX_MULTIPLY, // 16
    .INPLACE_MATRIX_MULTIPLY, // 17
    null, // 18 - <18>
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    null, // 21 - <21>
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    null, // 30 - <30>
    null, // 31 - <31>
    null, // 32 - <32>
    null, // 33 - <33>
    null, // 34 - <34>
    null, // 35 - <35>
    null, // 36 - <36>
    null, // 37 - <37>
    null, // 38 - <38>
    null, // 39 - <39>
    null, // 40 - <40>
    null, // 41 - <41>
    null, // 42 - <42>
    null, // 43 - <43>
    null, // 44 - <44>
    null, // 45 - <45>
    null, // 46 - <46>
    null, // 47 - <47>
    null, // 48 - <48>
    null, // 49 - <49>
    .GET_AITER, // 50
    .GET_ANEXT, // 51
    .BEFORE_ASYNC_WITH, // 52
    .BEGIN_FINALLY, // 53
    .END_ASYNC_FOR, // 54
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    null, // 58 - <58>
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    .GET_YIELD_FROM_ITER, // 69
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    .YIELD_FROM, // 72
    .GET_AWAITABLE, // 73
    null, // 74 - <74>
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    null, // 80 - <80>
    .WITH_CLEANUP_START, // 81
    .WITH_CLEANUP_FINISH, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    .SETUP_ANNOTATIONS, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    .END_FINALLY, // 88
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    null, // 99 - <99>
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE_OR_POP, // 111
    .JUMP_IF_TRUE_OR_POP, // 112
    .JUMP_ABSOLUTE, // 113
    .POP_JUMP_IF_FALSE, // 114
    .POP_JUMP_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    null, // 117 - <117>
    null, // 118 - <118>
    null, // 119 - <119>
    null, // 120 - <120>
    null, // 121 - <121>
    .SETUP_FINALLY, // 122
    null, // 123 - <123>
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    null, // 127 - <127>
    null, // 128 - <128>
    null, // 129 - <129>
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    null, // 134 - <134>
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    .DELETE_DEREF, // 138
    null, // 139 - <139>
    null, // 140 - <140>
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_EX, // 142
    .SETUP_WITH, // 143
    .EXTENDED_ARG, // 144
    .LIST_APPEND, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
    .LOAD_CLASSDEREF, // 148
    .BUILD_LIST_UNPACK, // 149
    .BUILD_MAP_UNPACK, // 150
    .BUILD_MAP_UNPACK_WITH_CALL, // 151
    .BUILD_TUPLE_UNPACK, // 152
    .BUILD_SET_UNPACK, // 153
    .SETUP_ASYNC_WITH, // 154
    .FORMAT_VALUE, // 155
    .BUILD_CONST_KEY_MAP, // 156
    .BUILD_STRING, // 157
    .BUILD_TUPLE_UNPACK_WITH_CALL, // 158
    null, // 159 - <159>
    .LOAD_METHOD, // 160
    .CALL_METHOD, // 161
    .CALL_FINALLY, // 162
    .POP_FINALLY, // 163
    null, // 164 - <164>
    null, // 165 - <165>
    null, // 166 - <166>
    null, // 167 - <167>
    null, // 168 - <168>
    null, // 169 - <169>
    null, // 170 - <170>
    null, // 171 - <171>
    null, // 172 - <172>
    null, // 173 - <173>
    null, // 174 - <174>
    null, // 175 - <175>
    null, // 176 - <176>
    null, // 177 - <177>
    null, // 178 - <178>
    null, // 179 - <179>
    null, // 180 - <180>
    null, // 181 - <181>
    null, // 182 - <182>
    null, // 183 - <183>
    null, // 184 - <184>
    null, // 185 - <185>
    null, // 186 - <186>
    null, // 187 - <187>
    null, // 188 - <188>
    null, // 189 - <189>
    null, // 190 - <190>
    null, // 191 - <191>
    null, // 192 - <192>
    null, // 193 - <193>
    null, // 194 - <194>
    null, // 195 - <195>
    null, // 196 - <196>
    null, // 197 - <197>
    null, // 198 - <198>
    null, // 199 - <199>
    null, // 200 - <200>
    null, // 201 - <201>
    null, // 202 - <202>
    null, // 203 - <203>
    null, // 204 - <204>
    null, // 205 - <205>
    null, // 206 - <206>
    null, // 207 - <207>
    null, // 208 - <208>
    null, // 209 - <209>
    null, // 210 - <210>
    null, // 211 - <211>
    null, // 212 - <212>
    null, // 213 - <213>
    null, // 214 - <214>
    null, // 215 - <215>
    null, // 216 - <216>
    null, // 217 - <217>
    null, // 218 - <218>
    null, // 219 - <219>
    null, // 220 - <220>
    null, // 221 - <221>
    null, // 222 - <222>
    null, // 223 - <223>
    null, // 224 - <224>
    null, // 225 - <225>
    null, // 226 - <226>
    null, // 227 - <227>
    null, // 228 - <228>
    null, // 229 - <229>
    null, // 230 - <230>
    null, // 231 - <231>
    null, // 232 - <232>
    null, // 233 - <233>
    null, // 234 - <234>
    null, // 235 - <235>
    null, // 236 - <236>
    null, // 237 - <237>
    null, // 238 - <238>
    null, // 239 - <239>
    null, // 240 - <240>
    null, // 241 - <241>
    null, // 242 - <242>
    null, // 243 - <243>
    null, // 244 - <244>
    null, // 245 - <245>
    null, // 246 - <246>
    null, // 247 - <247>
    null, // 248 - <248>
    null, // 249 - <249>
    null, // 250 - <250>
    null, // 251 - <251>
    null, // 252 - <252>
    null, // 253 - <253>
    null, // 254 - <254>
    null, // 255 - <255>
};

/// Python 3.7 opcode byte values
const opcode_table_3_7 = [_]?Opcode{
    null, // 0 - <0>
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .DUP_TOP_TWO, // 5
    null, // 6 - <6>
    null, // 7 - <7>
    null, // 8 - <8>
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13 - <13>
    null, // 14 - <14>
    .UNARY_INVERT, // 15
    .BINARY_MATRIX_MULTIPLY, // 16
    .INPLACE_MATRIX_MULTIPLY, // 17
    null, // 18 - <18>
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    null, // 21 - <21>
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    null, // 30 - <30>
    null, // 31 - <31>
    null, // 32 - <32>
    null, // 33 - <33>
    null, // 34 - <34>
    null, // 35 - <35>
    null, // 36 - <36>
    null, // 37 - <37>
    null, // 38 - <38>
    null, // 39 - <39>
    null, // 40 - <40>
    null, // 41 - <41>
    null, // 42 - <42>
    null, // 43 - <43>
    null, // 44 - <44>
    null, // 45 - <45>
    null, // 46 - <46>
    null, // 47 - <47>
    null, // 48 - <48>
    null, // 49 - <49>
    .GET_AITER, // 50
    .GET_ANEXT, // 51
    .BEFORE_ASYNC_WITH, // 52
    null, // 53 - <53>
    null, // 54 - <54>
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    null, // 58 - <58>
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    .GET_YIELD_FROM_ITER, // 69
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    .YIELD_FROM, // 72
    .GET_AWAITABLE, // 73
    null, // 74 - <74>
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    .BREAK_LOOP, // 80
    .WITH_CLEANUP_START, // 81
    .WITH_CLEANUP_FINISH, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    .SETUP_ANNOTATIONS, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    .END_FINALLY, // 88
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    null, // 99 - <99>
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE_OR_POP, // 111
    .JUMP_IF_TRUE_OR_POP, // 112
    .JUMP_ABSOLUTE, // 113
    .POP_JUMP_IF_FALSE, // 114
    .POP_JUMP_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    null, // 117 - <117>
    null, // 118 - <118>
    .CONTINUE_LOOP, // 119
    .SETUP_LOOP, // 120
    .SETUP_EXCEPT, // 121
    .SETUP_FINALLY, // 122
    null, // 123 - <123>
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    null, // 127 - <127>
    null, // 128 - <128>
    null, // 129 - <129>
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    null, // 134 - <134>
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    .DELETE_DEREF, // 138
    null, // 139 - <139>
    null, // 140 - <140>
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_EX, // 142
    .SETUP_WITH, // 143
    .EXTENDED_ARG, // 144
    .LIST_APPEND, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
    .LOAD_CLASSDEREF, // 148
    .BUILD_LIST_UNPACK, // 149
    .BUILD_MAP_UNPACK, // 150
    .BUILD_MAP_UNPACK_WITH_CALL, // 151
    .BUILD_TUPLE_UNPACK, // 152
    .BUILD_SET_UNPACK, // 153
    .SETUP_ASYNC_WITH, // 154
    .FORMAT_VALUE, // 155
    .BUILD_CONST_KEY_MAP, // 156
    .BUILD_STRING, // 157
    .BUILD_TUPLE_UNPACK_WITH_CALL, // 158
    null, // 159 - <159>
    .LOAD_METHOD, // 160
    .CALL_METHOD, // 161
    null, // 162 - <162>
    null, // 163 - <163>
    null, // 164 - <164>
    null, // 165 - <165>
    null, // 166 - <166>
    null, // 167 - <167>
    null, // 168 - <168>
    null, // 169 - <169>
    null, // 170 - <170>
    null, // 171 - <171>
    null, // 172 - <172>
    null, // 173 - <173>
    null, // 174 - <174>
    null, // 175 - <175>
    null, // 176 - <176>
    null, // 177 - <177>
    null, // 178 - <178>
    null, // 179 - <179>
    null, // 180 - <180>
    null, // 181 - <181>
    null, // 182 - <182>
    null, // 183 - <183>
    null, // 184 - <184>
    null, // 185 - <185>
    null, // 186 - <186>
    null, // 187 - <187>
    null, // 188 - <188>
    null, // 189 - <189>
    null, // 190 - <190>
    null, // 191 - <191>
    null, // 192 - <192>
    null, // 193 - <193>
    null, // 194 - <194>
    null, // 195 - <195>
    null, // 196 - <196>
    null, // 197 - <197>
    null, // 198 - <198>
    null, // 199 - <199>
    null, // 200 - <200>
    null, // 201 - <201>
    null, // 202 - <202>
    null, // 203 - <203>
    null, // 204 - <204>
    null, // 205 - <205>
    null, // 206 - <206>
    null, // 207 - <207>
    null, // 208 - <208>
    null, // 209 - <209>
    null, // 210 - <210>
    null, // 211 - <211>
    null, // 212 - <212>
    null, // 213 - <213>
    null, // 214 - <214>
    null, // 215 - <215>
    null, // 216 - <216>
    null, // 217 - <217>
    null, // 218 - <218>
    null, // 219 - <219>
    null, // 220 - <220>
    null, // 221 - <221>
    null, // 222 - <222>
    null, // 223 - <223>
    null, // 224 - <224>
    null, // 225 - <225>
    null, // 226 - <226>
    null, // 227 - <227>
    null, // 228 - <228>
    null, // 229 - <229>
    null, // 230 - <230>
    null, // 231 - <231>
    null, // 232 - <232>
    null, // 233 - <233>
    null, // 234 - <234>
    null, // 235 - <235>
    null, // 236 - <236>
    null, // 237 - <237>
    null, // 238 - <238>
    null, // 239 - <239>
    null, // 240 - <240>
    null, // 241 - <241>
    null, // 242 - <242>
    null, // 243 - <243>
    null, // 244 - <244>
    null, // 245 - <245>
    null, // 246 - <246>
    null, // 247 - <247>
    null, // 248 - <248>
    null, // 249 - <249>
    null, // 250 - <250>
    null, // 251 - <251>
    null, // 252 - <252>
    null, // 253 - <253>
    null, // 254 - <254>
    null, // 255 - <255>
};

/// Python 3.6 opcode byte values
const opcode_table_3_6 = [_]?Opcode{
    null, // 0 - <0>
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .DUP_TOP_TWO, // 5
    null, // 6 - <6>
    null, // 7 - <7>
    null, // 8 - <8>
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13 - <13>
    null, // 14 - <14>
    .UNARY_INVERT, // 15
    .BINARY_MATRIX_MULTIPLY, // 16
    .INPLACE_MATRIX_MULTIPLY, // 17
    null, // 18 - <18>
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    null, // 21 - <21>
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    null, // 30 - <30>
    null, // 31 - <31>
    null, // 32 - <32>
    null, // 33 - <33>
    null, // 34 - <34>
    null, // 35 - <35>
    null, // 36 - <36>
    null, // 37 - <37>
    null, // 38 - <38>
    null, // 39 - <39>
    null, // 40 - <40>
    null, // 41 - <41>
    null, // 42 - <42>
    null, // 43 - <43>
    null, // 44 - <44>
    null, // 45 - <45>
    null, // 46 - <46>
    null, // 47 - <47>
    null, // 48 - <48>
    null, // 49 - <49>
    .GET_AITER, // 50
    .GET_ANEXT, // 51
    .BEFORE_ASYNC_WITH, // 52
    null, // 53 - <53>
    null, // 54 - <54>
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    null, // 58 - <58>
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    .GET_YIELD_FROM_ITER, // 69
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    .YIELD_FROM, // 72
    .GET_AWAITABLE, // 73
    null, // 74 - <74>
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    .BREAK_LOOP, // 80
    .WITH_CLEANUP_START, // 81
    .WITH_CLEANUP_FINISH, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    .SETUP_ANNOTATIONS, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    .END_FINALLY, // 88
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    null, // 99 - <99>
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE_OR_POP, // 111
    .JUMP_IF_TRUE_OR_POP, // 112
    .JUMP_ABSOLUTE, // 113
    .POP_JUMP_IF_FALSE, // 114
    .POP_JUMP_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    null, // 117 - <117>
    null, // 118 - <118>
    .CONTINUE_LOOP, // 119
    .SETUP_LOOP, // 120
    .SETUP_EXCEPT, // 121
    .SETUP_FINALLY, // 122
    null, // 123 - <123>
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    .STORE_ANNOTATION, // 127
    null, // 128 - <128>
    null, // 129 - <129>
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    null, // 134 - <134>
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    .DELETE_DEREF, // 138
    null, // 139 - <139>
    null, // 140 - <140>
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_EX, // 142
    .SETUP_WITH, // 143
    .EXTENDED_ARG, // 144
    .LIST_APPEND, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
    .LOAD_CLASSDEREF, // 148
    .BUILD_LIST_UNPACK, // 149
    .BUILD_MAP_UNPACK, // 150
    .BUILD_MAP_UNPACK_WITH_CALL, // 151
    .BUILD_TUPLE_UNPACK, // 152
    .BUILD_SET_UNPACK, // 153
    .SETUP_ASYNC_WITH, // 154
    .FORMAT_VALUE, // 155
    .BUILD_CONST_KEY_MAP, // 156
    .BUILD_STRING, // 157
    .BUILD_TUPLE_UNPACK_WITH_CALL, // 158
    null, // 159 - <159>
    null, // 160 - <160>
    null, // 161 - <161>
    null, // 162 - <162>
    null, // 163 - <163>
    null, // 164 - <164>
    null, // 165 - <165>
    null, // 166 - <166>
    null, // 167 - <167>
    null, // 168 - <168>
    null, // 169 - <169>
    null, // 170 - <170>
    null, // 171 - <171>
    null, // 172 - <172>
    null, // 173 - <173>
    null, // 174 - <174>
    null, // 175 - <175>
    null, // 176 - <176>
    null, // 177 - <177>
    null, // 178 - <178>
    null, // 179 - <179>
    null, // 180 - <180>
    null, // 181 - <181>
    null, // 182 - <182>
    null, // 183 - <183>
    null, // 184 - <184>
    null, // 185 - <185>
    null, // 186 - <186>
    null, // 187 - <187>
    null, // 188 - <188>
    null, // 189 - <189>
    null, // 190 - <190>
    null, // 191 - <191>
    null, // 192 - <192>
    null, // 193 - <193>
    null, // 194 - <194>
    null, // 195 - <195>
    null, // 196 - <196>
    null, // 197 - <197>
    null, // 198 - <198>
    null, // 199 - <199>
    null, // 200 - <200>
    null, // 201 - <201>
    null, // 202 - <202>
    null, // 203 - <203>
    null, // 204 - <204>
    null, // 205 - <205>
    null, // 206 - <206>
    null, // 207 - <207>
    null, // 208 - <208>
    null, // 209 - <209>
    null, // 210 - <210>
    null, // 211 - <211>
    null, // 212 - <212>
    null, // 213 - <213>
    null, // 214 - <214>
    null, // 215 - <215>
    null, // 216 - <216>
    null, // 217 - <217>
    null, // 218 - <218>
    null, // 219 - <219>
    null, // 220 - <220>
    null, // 221 - <221>
    null, // 222 - <222>
    null, // 223 - <223>
    null, // 224 - <224>
    null, // 225 - <225>
    null, // 226 - <226>
    null, // 227 - <227>
    null, // 228 - <228>
    null, // 229 - <229>
    null, // 230 - <230>
    null, // 231 - <231>
    null, // 232 - <232>
    null, // 233 - <233>
    null, // 234 - <234>
    null, // 235 - <235>
    null, // 236 - <236>
    null, // 237 - <237>
    null, // 238 - <238>
    null, // 239 - <239>
    null, // 240 - <240>
    null, // 241 - <241>
    null, // 242 - <242>
    null, // 243 - <243>
    null, // 244 - <244>
    null, // 245 - <245>
    null, // 246 - <246>
    null, // 247 - <247>
    null, // 248 - <248>
    null, // 249 - <249>
    null, // 250 - <250>
    null, // 251 - <251>
    null, // 252 - <252>
    null, // 253 - <253>
    null, // 254 - <254>
    null, // 255 - <255>
};

/// Python 2.7 opcode byte values
/// Python 2.5-2.6 opcode table (BUILD_MAP at 104, no BUILD_SET)
const opcode_table_2_6 = [_]?Opcode{
    .STOP_CODE, // 0
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .ROT_FOUR, // 5
    null, // 6
    null, // 7
    null, // 8
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    .UNARY_CONVERT, // 13
    null, // 14
    .UNARY_INVERT, // 15
    null, // 16
    null, // 17
    null, // 18
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    .BINARY_DIVIDE, // 21
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    .SLICE_0, // 30
    .SLICE_1, // 31
    .SLICE_2, // 32
    .SLICE_3, // 33
    null, // 34
    null, // 35
    null, // 36
    null, // 37
    null, // 38
    null, // 39
    .STORE_SLICE_0, // 40
    .STORE_SLICE_1, // 41
    .STORE_SLICE_2, // 42
    .STORE_SLICE_3, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    null, // 49
    .DELETE_SLICE_0, // 50
    .DELETE_SLICE_1, // 51
    .DELETE_SLICE_2, // 52
    .DELETE_SLICE_3, // 53
    .STORE_MAP, // 54
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    .INPLACE_DIVIDE, // 58
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    null, // 69
    .PRINT_EXPR, // 70
    .PRINT_ITEM, // 71
    .PRINT_NEWLINE, // 72
    .PRINT_ITEM_TO, // 73
    .PRINT_NEWLINE_TO, // 74
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    .BREAK_LOOP, // 80
    .WITH_CLEANUP, // 81
    .LOAD_LOCALS, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    .EXEC_STMT, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    .END_FINALLY, // 88
    .BUILD_CLASS, // 89
    .STORE_NAME, // 90 (HAVE_ARGUMENT)
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .LIST_APPEND, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    .DUP_TOPX, // 99
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_MAP, // 104 - Python 2.5/2.6 BUILD_MAP is at 104
    .LOAD_ATTR, // 105
    .COMPARE_OP, // 106
    .IMPORT_NAME, // 107
    .IMPORT_FROM, // 108
    null, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE, // 111 - Python 2.5/2.6: JUMP_IF_FALSE (not OR_POP variant)
    .JUMP_IF_TRUE, // 112 - Python 2.5/2.6: JUMP_IF_TRUE (not OR_POP variant)
    .JUMP_ABSOLUTE, // 113
    null, // 114 - POP_JUMP_IF_FALSE is Python 2.7+
    null, // 115 - POP_JUMP_IF_TRUE is Python 2.7+
    .LOAD_GLOBAL, // 116
    null, // 117
    null, // 118
    .CONTINUE_LOOP, // 119
    .SETUP_LOOP, // 120
    .SETUP_EXCEPT, // 121
    .SETUP_FINALLY, // 122
    null, // 123
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    .SET_LINENO, // 127
    null, // 128
    null, // 129
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    .MAKE_CLOSURE, // 134
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    null, // 138
    null, // 139
    .CALL_FUNCTION_VAR, // 140
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_VAR_KW, // 142
    .EXTENDED_ARG, // 143
};

/// Python 2.7 opcode table (BUILD_SET added at 104)
const opcode_table_2_7 = [_]?Opcode{
    .STOP_CODE, // 0
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .ROT_FOUR, // 5
    null, // 6
    null, // 7
    null, // 8
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    .UNARY_CONVERT, // 13
    null, // 14
    .UNARY_INVERT, // 15
    null, // 16
    null, // 17
    null, // 18
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    .BINARY_DIVIDE, // 21
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    .SLICE_0, // 30
    .SLICE_1, // 31
    .SLICE_2, // 32
    .SLICE_3, // 33
    null, // 34
    null, // 35
    null, // 36
    null, // 37
    null, // 38
    null, // 39
    .STORE_SLICE_0, // 40
    .STORE_SLICE_1, // 41
    .STORE_SLICE_2, // 42
    .STORE_SLICE_3, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    null, // 49
    .DELETE_SLICE_0, // 50
    .DELETE_SLICE_1, // 51
    .DELETE_SLICE_2, // 52
    .DELETE_SLICE_3, // 53
    .STORE_MAP, // 54
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    .INPLACE_DIVIDE, // 58
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    null, // 69
    .PRINT_EXPR, // 70
    .PRINT_ITEM, // 71
    .PRINT_NEWLINE, // 72
    .PRINT_ITEM_TO, // 73
    .PRINT_NEWLINE_TO, // 74
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    .BREAK_LOOP, // 80
    .WITH_CLEANUP, // 81
    .LOAD_LOCALS, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    .EXEC_STMT, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    .END_FINALLY, // 88
    .BUILD_CLASS, // 89
    .STORE_NAME, // 90 (HAVE_ARGUMENT)
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .LIST_APPEND, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    .DUP_TOPX, // 99
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE_OR_POP, // 111
    .JUMP_IF_TRUE_OR_POP, // 112
    .JUMP_ABSOLUTE, // 113
    .POP_JUMP_IF_FALSE, // 114
    .POP_JUMP_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    null, // 117
    null, // 118
    .CONTINUE_LOOP, // 119
    .SETUP_LOOP, // 120
    .SETUP_EXCEPT, // 121
    .SETUP_FINALLY, // 122
    null, // 123
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    .SET_LINENO, // 127
    null, // 128
    null, // 129
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    .MAKE_CLOSURE, // 134
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    null, // 138
    null, // 139
    .CALL_FUNCTION_VAR, // 140
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_VAR_KW, // 142
    .SETUP_WITH, // 143
    null, // 144
    .EXTENDED_ARG, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
};

/// Python 3.1-3.4 opcode byte values (variable-length instructions like Python 2)
/// Changes from 3.0: JUMP_IF_FALSE/TRUE -> JUMP_IF_FALSE/TRUE_OR_POP,
/// added POP_JUMP_IF_FALSE/TRUE, moved SET_ADD/LIST_APPEND, added MAP_ADD
const opcode_table_3_1 = [_]?Opcode{
    .STOP_CODE, // 0
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .ROT_FOUR, // 5
    null, // 6
    null, // 7
    null, // 8
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13
    null, // 14
    .UNARY_INVERT, // 15
    null, // 16
    null, // 17
    null, // 18
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    null, // 21
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    null, // 30
    null, // 31
    null, // 32
    null, // 33
    null, // 34
    null, // 35
    null, // 36
    null, // 37
    null, // 38
    null, // 39
    null, // 40
    null, // 41
    null, // 42
    null, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    null, // 49
    null, // 50
    null, // 51
    null, // 52
    null, // 53
    .STORE_MAP, // 54
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    null, // 58
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    .STORE_LOCALS, // 69
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    null, // 72
    null, // 73
    null, // 74
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    .BREAK_LOOP, // 80
    .WITH_CLEANUP, // 81
    null, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    null, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    .END_FINALLY, // 88
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    .DUP_TOPX, // 99
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE_OR_POP, // 111 - changed in 3.1
    .JUMP_IF_TRUE_OR_POP, // 112 - changed in 3.1
    .JUMP_ABSOLUTE, // 113
    .POP_JUMP_IF_FALSE, // 114 - new in 3.1
    .POP_JUMP_IF_TRUE, // 115 - new in 3.1
    .LOAD_GLOBAL, // 116
    null, // 117
    null, // 118
    .CONTINUE_LOOP, // 119
    .SETUP_LOOP, // 120
    .SETUP_EXCEPT, // 121
    .SETUP_FINALLY, // 122
    null, // 123
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    .SET_LINENO, // 127
    null, // 128
    null, // 129
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    .MAKE_CLOSURE, // 134
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    null, // 138
    null, // 139
    .CALL_FUNCTION_VAR, // 140
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_VAR_KW, // 142
    .EXTENDED_ARG, // 143
    null, // 144
    .LIST_APPEND, // 145 - new position in 3.1+
    .SET_ADD, // 146 - new position in 3.1+
    .MAP_ADD, // 147 - new in 3.1+
    .LOAD_CLASSDEREF, // 148 - new in 3.4
};

/// Python 3.5 opcode byte values (adds async/await, matrix multiply)
const opcode_table_3_5 = [_]?Opcode{
    .STOP_CODE, // 0
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .ROT_FOUR, // 5
    null, // 6
    null, // 7
    null, // 8
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13
    null, // 14
    .UNARY_INVERT, // 15
    .BINARY_MATRIX_MULTIPLY, // 16 - new in 3.5
    .INPLACE_MATRIX_MULTIPLY, // 17 - new in 3.5
    null, // 18
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    null, // 21
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    null, // 30
    null, // 31
    null, // 32
    null, // 33
    null, // 34
    null, // 35
    null, // 36
    null, // 37
    null, // 38
    null, // 39
    null, // 40
    null, // 41
    null, // 42
    null, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    null, // 49
    .GET_AITER, // 50 - new in 3.5
    .GET_ANEXT, // 51 - new in 3.5
    .BEFORE_ASYNC_WITH, // 52 - new in 3.5
    null, // 53
    .STORE_MAP, // 54
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    null, // 58
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    .GET_YIELD_FROM_ITER, // 69 - new in 3.5
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    .YIELD_FROM, // 72 - new in 3.5
    .GET_AWAITABLE, // 73 - new in 3.5
    null, // 74
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    .BREAK_LOOP, // 80
    .WITH_CLEANUP, // 81
    null, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    null, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    .END_FINALLY, // 88
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    .DUP_TOPX, // 99
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE_OR_POP, // 111
    .JUMP_IF_TRUE_OR_POP, // 112
    .JUMP_ABSOLUTE, // 113
    .POP_JUMP_IF_FALSE, // 114
    .POP_JUMP_IF_TRUE, // 115
    .LOAD_GLOBAL, // 116
    null, // 117
    null, // 118
    .CONTINUE_LOOP, // 119
    .SETUP_LOOP, // 120
    .SETUP_EXCEPT, // 121
    .SETUP_FINALLY, // 122
    null, // 123
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    .SET_LINENO, // 127
    null, // 128
    null, // 129
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    .MAKE_CLOSURE, // 134
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    null, // 138
    null, // 139
    .CALL_FUNCTION_VAR, // 140
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_VAR_KW, // 142
    .EXTENDED_ARG, // 143
    null, // 144
    .LIST_APPEND, // 145
    .SET_ADD, // 146
    .MAP_ADD, // 147
    .LOAD_CLASSDEREF, // 148 - new in 3.4, kept in 3.5
    null, // 149
    null, // 150
    null, // 151
    null, // 152
    null, // 153
    null, // 154
    null, // 155
    null, // 156
    null, // 157
    null, // 158
    null, // 159
    null, // 160
};

/// Python 3.0 opcode byte values (variable-length instructions like Python 2)
const opcode_table_3_0 = [_]?Opcode{
    .STOP_CODE, // 0
    .POP_TOP, // 1
    .ROT_TWO, // 2
    .ROT_THREE, // 3
    .DUP_TOP, // 4
    .ROT_FOUR, // 5
    null, // 6
    null, // 7
    null, // 8
    .NOP, // 9
    .UNARY_POSITIVE, // 10
    .UNARY_NEGATIVE, // 11
    .UNARY_NOT, // 12
    null, // 13
    null, // 14
    .UNARY_INVERT, // 15
    null, // 16
    .SET_ADD, // 17 - different position from 3.6+
    .LIST_APPEND, // 18 - different position from 3.6+
    .BINARY_POWER, // 19
    .BINARY_MULTIPLY, // 20
    null, // 21
    .BINARY_MODULO, // 22
    .BINARY_ADD, // 23
    .BINARY_SUBTRACT, // 24
    .BINARY_SUBSCR, // 25
    .BINARY_FLOOR_DIVIDE, // 26
    .BINARY_TRUE_DIVIDE, // 27
    .INPLACE_FLOOR_DIVIDE, // 28
    .INPLACE_TRUE_DIVIDE, // 29
    null, // 30
    null, // 31
    null, // 32
    null, // 33
    null, // 34
    null, // 35
    null, // 36
    null, // 37
    null, // 38
    null, // 39
    null, // 40
    null, // 41
    null, // 42
    null, // 43
    null, // 44
    null, // 45
    null, // 46
    null, // 47
    null, // 48
    null, // 49
    null, // 50
    null, // 51
    null, // 52
    null, // 53
    .STORE_MAP, // 54
    .INPLACE_ADD, // 55
    .INPLACE_SUBTRACT, // 56
    .INPLACE_MULTIPLY, // 57
    null, // 58
    .INPLACE_MODULO, // 59
    .STORE_SUBSCR, // 60
    .DELETE_SUBSCR, // 61
    .BINARY_LSHIFT, // 62
    .BINARY_RSHIFT, // 63
    .BINARY_AND, // 64
    .BINARY_XOR, // 65
    .BINARY_OR, // 66
    .INPLACE_POWER, // 67
    .GET_ITER, // 68
    .STORE_LOCALS, // 69
    .PRINT_EXPR, // 70
    .LOAD_BUILD_CLASS, // 71
    null, // 72
    null, // 73
    null, // 74
    .INPLACE_LSHIFT, // 75
    .INPLACE_RSHIFT, // 76
    .INPLACE_AND, // 77
    .INPLACE_XOR, // 78
    .INPLACE_OR, // 79
    .BREAK_LOOP, // 80
    .WITH_CLEANUP, // 81
    null, // 82
    .RETURN_VALUE, // 83
    .IMPORT_STAR, // 84
    null, // 85
    .YIELD_VALUE, // 86
    .POP_BLOCK, // 87
    .END_FINALLY, // 88
    .POP_EXCEPT, // 89
    .STORE_NAME, // 90
    .DELETE_NAME, // 91
    .UNPACK_SEQUENCE, // 92
    .FOR_ITER, // 93
    .UNPACK_EX, // 94
    .STORE_ATTR, // 95
    .DELETE_ATTR, // 96
    .STORE_GLOBAL, // 97
    .DELETE_GLOBAL, // 98
    .DUP_TOPX, // 99
    .LOAD_CONST, // 100
    .LOAD_NAME, // 101
    .BUILD_TUPLE, // 102
    .BUILD_LIST, // 103
    .BUILD_SET, // 104
    .BUILD_MAP, // 105
    .LOAD_ATTR, // 106
    .COMPARE_OP, // 107
    .IMPORT_NAME, // 108
    .IMPORT_FROM, // 109
    .JUMP_FORWARD, // 110
    .JUMP_IF_FALSE, // 111 - Python 3.0 specific
    .JUMP_IF_TRUE, // 112 - Python 3.0 specific
    .JUMP_ABSOLUTE, // 113
    null, // 114
    null, // 115
    .LOAD_GLOBAL, // 116
    null, // 117
    null, // 118
    .CONTINUE_LOOP, // 119
    .SETUP_LOOP, // 120
    .SETUP_EXCEPT, // 121
    .SETUP_FINALLY, // 122
    null, // 123
    .LOAD_FAST, // 124
    .STORE_FAST, // 125
    .DELETE_FAST, // 126
    .SET_LINENO, // 127
    null, // 128
    null, // 129
    .RAISE_VARARGS, // 130
    .CALL_FUNCTION, // 131
    .MAKE_FUNCTION, // 132
    .BUILD_SLICE, // 133
    .MAKE_CLOSURE, // 134
    .LOAD_CLOSURE, // 135
    .LOAD_DEREF, // 136
    .STORE_DEREF, // 137
    null, // 138
    null, // 139
    .CALL_FUNCTION_VAR, // 140
    .CALL_FUNCTION_KW, // 141
    .CALL_FUNCTION_VAR_KW, // 142
    .EXTENDED_ARG, // 143
};

/// Get the opcode table for a Python version.
pub fn getOpcodeTable(ver: Version) []const ?Opcode {
    if (ver.gte(3, 14)) return &opcode_table_3_14;
    if (ver.gte(3, 13)) return &opcode_table_3_13;
    if (ver.gte(3, 12)) return &opcode_table_3_12;
    if (ver.gte(3, 11)) return &opcode_table_3_11;
    if (ver.gte(3, 10)) return &opcode_table_3_10;
    if (ver.gte(3, 9)) return &opcode_table_3_9;
    if (ver.gte(3, 8)) return &opcode_table_3_8;
    if (ver.gte(3, 7)) return &opcode_table_3_7;
    if (ver.gte(3, 6)) return &opcode_table_3_6;
    if (ver.gte(3, 5)) return &opcode_table_3_5; // Python 3.5
    if (ver.gte(3, 1)) return &opcode_table_3_1; // Python 3.1-3.4
    if (ver.major == 3) return &opcode_table_3_0; // Python 3.0
    if (ver.gte(2, 7)) return &opcode_table_2_7; // Python 2.7
    if (ver.major == 2) return &opcode_table_2_6; // Python 2.5-2.6
    std.debug.panic("unsupported Python version {d}.{d}", .{ ver.major, ver.minor });
}

/// Map raw bytecode value to opcode based on Python version.
/// Returns null for invalid/unknown opcodes.
pub fn byteToOpcode(ver: Version, byte: u8) ?Opcode {
    const table = getOpcodeTable(ver);
    if (byte < table.len) return table[byte];
    return null;
}

/// Map opcode to byte value for a specific Python version.
/// Returns null if the opcode doesn't exist in that version.
fn opcodeToByteImpl(ver: Version, op: Opcode) ?u8 {
    const table = getOpcodeTable(ver);
    for (table, 0..) |entry, i| {
        if (entry == op) return @intCast(i);
    }
    return null;
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

/// Number of inline cache entries following an opcode (Python 3.11+).
/// Cache entries are 16-bit words that follow certain opcodes.
pub fn cacheEntries(op: Opcode, ver: Version) u8 {
    // Pre-3.11 has no inline caches
    if (ver.lt(3, 11)) return 0;

    // Python 3.11 has different cache sizes than 3.12+
    if (ver.lt(3, 12)) {
        return switch (op) {
            .BINARY_SUBSCR => 4,
            .STORE_SUBSCR => 1,
            .BINARY_OP => 1,
            .UNPACK_SEQUENCE => 1,
            .FOR_ITER => 1,
            .LOAD_ATTR => 4, // Only 4 in 3.11 (different from LOAD_METHOD)
            .LOAD_METHOD => 10, // LOAD_METHOD has 10 cache entries in 3.11
            .STORE_ATTR => 4,
            .COMPARE_OP => 2,
            .LOAD_GLOBAL => 5,
            .CALL => 4,
            .PRECALL => 1, // 3.11 only
            .SEND => 1,
            else => 0,
        };
    }

    // Python 3.12 cache sizes (from opcode._cache_format)
    if (ver.lt(3, 13)) {
        return switch (op) {
            .BINARY_SUBSCR => 1,
            .STORE_SUBSCR => 1,
            .BINARY_OP => 1,
            .UNPACK_SEQUENCE => 1,
            .FOR_ITER => 1,
            .LOAD_ATTR => 9,
            .STORE_ATTR => 4,
            .COMPARE_OP => 1,
            .LOAD_GLOBAL => 4,
            .LOAD_SUPER_ATTR => 1,
            .CALL => 3,
            .SEND => 1,
            else => 0,
        };
    }

    // Python 3.13+ cache entry counts
    return switch (op) {
        .TO_BOOL => 3,
        .BINARY_SUBSCR => 1,
        .STORE_SUBSCR => 1,
        .BINARY_OP => 1, // Reduced from 5 in 3.12
        .UNPACK_SEQUENCE => 1,
        .FOR_ITER => 1,
        .LOAD_ATTR => 9,
        .STORE_ATTR => 4,
        .COMPARE_OP => 1,
        .LOAD_GLOBAL => 4,
        .LOAD_SUPER_ATTR => 1,
        .CALL => 3,
        .CONTAINS_OP => 1,
        .SEND => 1,
        .JUMP_BACKWARD => 1,
        .POP_JUMP_IF_TRUE => 1,
        .POP_JUMP_IF_FALSE => 1,
        .POP_JUMP_IF_NONE => 1,
        .POP_JUMP_IF_NOT_NONE => 1,
        else => 0,
    };
}

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

test "opcode has arg 3.11" {
    const testing = std.testing;
    const v311 = Version.init(3, 11);
    try testing.expect(!Opcode.POP_TOP.hasArg(v311));
    try testing.expect(!Opcode.RETURN_VALUE.hasArg(v311));
    try testing.expect(Opcode.LOAD_CONST.hasArg(v311));
    try testing.expect(Opcode.LOAD_FAST.hasArg(v311));
    try testing.expect(Opcode.CALL.hasArg(v311));
}

test "opcode has arg 3.14" {
    const testing = std.testing;
    const v314 = Version.init(3, 14);
    // In 3.14, HAVE_ARGUMENT is 43, so more opcodes have args
    try testing.expect(!Opcode.POP_TOP.hasArg(v314)); // 31 < 43
    try testing.expect(!Opcode.RETURN_VALUE.hasArg(v314)); // 35 < 43
    try testing.expect(Opcode.LOAD_CONST.hasArg(v314)); // 82 >= 43
    try testing.expect(Opcode.LOAD_FAST.hasArg(v314)); // 84 >= 43
    try testing.expect(Opcode.CALL.hasArg(v314)); // 52 >= 43
    try testing.expect(Opcode.BINARY_OP.hasArg(v314)); // 44 >= 43
}

test "byteToOpcode 3.14" {
    const testing = std.testing;
    const v314 = Version.init(3, 14);

    // Test some 3.14 mappings
    try testing.expectEqual(Opcode.RESUME, byteToOpcode(v314, 128).?);
    try testing.expectEqual(Opcode.LOAD_CONST, byteToOpcode(v314, 82).?);
    try testing.expectEqual(Opcode.LOAD_NAME, byteToOpcode(v314, 93).?);
    try testing.expectEqual(Opcode.STORE_NAME, byteToOpcode(v314, 116).?);
    try testing.expectEqual(Opcode.MAKE_FUNCTION, byteToOpcode(v314, 23).?);
    try testing.expectEqual(Opcode.COMPARE_OP, byteToOpcode(v314, 56).?);
}

test "byteToOpcode 3.11" {
    const testing = std.testing;
    const v311 = Version.init(3, 11);

    // Test some 3.11 mappings
    try testing.expectEqual(Opcode.RESUME, byteToOpcode(v311, 151).?);
    try testing.expectEqual(Opcode.LOAD_CONST, byteToOpcode(v311, 100).?);
    try testing.expectEqual(Opcode.LOAD_NAME, byteToOpcode(v311, 101).?);
    try testing.expectEqual(Opcode.STORE_NAME, byteToOpcode(v311, 90).?);
    try testing.expectEqual(Opcode.MAKE_FUNCTION, byteToOpcode(v311, 132).?);
    try testing.expectEqual(Opcode.POP_JUMP_FORWARD_IF_FALSE, byteToOpcode(v311, 114).?);
    try testing.expectEqual(Opcode.POP_JUMP_BACKWARD_IF_FALSE, byteToOpcode(v311, 175).?);
}

test "byteToOpcode 3.10" {
    const testing = std.testing;
    const v310 = Version.init(3, 10);

    // Test some 3.10 mappings
    try testing.expectEqual(Opcode.LOAD_CONST, byteToOpcode(v310, 100).?);
    try testing.expectEqual(Opcode.CALL_FUNCTION, byteToOpcode(v310, 131).?);
    try testing.expectEqual(Opcode.LOAD_METHOD, byteToOpcode(v310, 160).?);
    try testing.expectEqual(Opcode.CALL_METHOD, byteToOpcode(v310, 161).?);
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
