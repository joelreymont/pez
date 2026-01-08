# Python Bytecode Decompilation Reference

This document contains comprehensive technical knowledge about Python bytecode format, marshalling, opcode encoding, and decompilation strategies.

## Table of Contents

1. [.pyc File Format](#pyc-file-format)
2. [Magic Numbers](#magic-numbers)
3. [Header Format](#header-format)
4. [Marshal Protocol](#marshal-protocol)
5. [Code Object Structure](#code-object-structure)
6. [Opcode Encoding](#opcode-encoding)
7. [Instruction Decoding](#instruction-decoding)
8. [Control Flow Graph](#control-flow-graph)
9. [AST Reconstruction](#ast-reconstruction)
10. [Version Differences Summary](#version-differences-summary)

---

## .pyc File Format

Python bytecode files (.pyc) consist of three parts:

```
┌──────────────────────────────────┐
│ Magic Number (4 bytes)           │  ← Identifies Python version
├──────────────────────────────────┤
│ Header (4-16 bytes, varies)      │  ← Timestamp, hash, source size
├──────────────────────────────────┤
│ Marshalled Code Object           │  ← The actual bytecode + metadata
└──────────────────────────────────┘
```

---

## Magic Numbers

Magic numbers are 4-byte little-endian values identifying the Python version. The pattern is typically `0x0A0D????`.

### Python 1.x
| Version | Magic Number |
|---------|--------------|
| 1.0     | `0x00999902` |
| 1.1-1.2 | `0x00999903` |
| 1.3     | `0x0A0D2E89` |
| 1.4     | `0x0A0D1704` |
| 1.5     | `0x0A0D4E99` |
| 1.6     | `0x0A0DC4FC` |

### Python 2.x
| Version | Magic Number |
|---------|--------------|
| 2.0     | `0x0A0DC687` |
| 2.1     | `0x0A0DEB2A` |
| 2.2     | `0x0A0DED2D` |
| 2.3     | `0x0A0DF23B` |
| 2.4     | `0x0A0DF26D` |
| 2.5     | `0x0A0DF2B3` |
| 2.6     | `0x0A0DF2D1` |
| 2.7     | `0x0A0DF303` |

### Python 3.x
| Version | Magic Number |
|---------|--------------|
| 3.0     | `0x0A0D0C3A` |
| 3.1     | `0x0A0D0C4E` |
| 3.2     | `0x0A0D0C6C` |
| 3.3     | `0x0A0D0C9E` |
| 3.4     | `0x0A0D0CEE` |
| 3.5     | `0x0A0D0D16` |
| 3.5.3   | `0x0A0D0D17` |
| 3.6     | `0x0A0D0D33` |
| 3.7     | `0x0A0D0D42` |
| 3.8     | `0x0A0D0D55` |
| 3.9     | `0x0A0D0D61` |
| 3.10    | `0x0A0D0D6F` |
| 3.11    | `0x0A0D0DA7` |
| 3.12    | `0x0A0D0DCB` |
| 3.13    | `0x0A0D0DF3` |
| 3.14    | `0x0A0D0E2B` |

### Unicode Mode (Python 1.6-2.7)
If `magic == standard_magic + 1`, Unicode mode is enabled. All Python 3.x is inherently Unicode.

---

## Header Format

Header size and format changed across versions:

| Version Range | Header Size | Fields |
|---------------|-------------|--------|
| Pre-3.3       | 4 bytes     | timestamp (u32) |
| 3.3-3.6       | 8 bytes     | timestamp (u32), source_size (u32) |
| 3.7+          | 12 bytes    | flags (u32), timestamp_or_hash (u32), source_size (u32) |

### 3.7+ Flags
- Bit 0: Hash-based (1) vs timestamp-based (0) invalidation
- When hash-based, the second field is a source hash instead of timestamp

---

## Marshal Protocol

Marshal uses single-byte type identifiers. Some types support FLAG_REF (0x80) for reference tracking.

### Type Identifiers

#### Atomic Types
| Type Code | Name | Description |
|-----------|------|-------------|
| `'0'` (0x30) | TYPE_NULL | Null value |
| `'N'` (0x4E) | TYPE_NONE | Python None |
| `'F'` (0x46) | TYPE_FALSE | Python False (3.8+) |
| `'T'` (0x54) | TYPE_TRUE | Python True (3.8+) |
| `'S'` (0x53) | TYPE_STOPITER | StopIteration |
| `'.'` (0x2E) | TYPE_ELLIPSIS | Ellipsis (...) |

#### Numeric Types
| Type Code | Name | Description |
|-----------|------|-------------|
| `'i'` (0x69) | TYPE_INT | 32-bit signed int |
| `'I'` (0x49) | TYPE_INT64 | 64-bit signed int |
| `'l'` (0x6C) | TYPE_LONG | Arbitrary precision int |
| `'f'` (0x66) | TYPE_FLOAT | ASCII float representation |
| `'g'` (0x67) | TYPE_BINARY_FLOAT | IEEE 754 binary float |
| `'x'` (0x78) | TYPE_COMPLEX | ASCII complex (real, imag) |
| `'y'` (0x79) | TYPE_BINARY_COMPLEX | IEEE 754 binary complex |

#### String/Bytes Types
| Type Code | Name | Description |
|-----------|------|-------------|
| `'s'` (0x73) | TYPE_STRING | Byte string (length-prefixed u32) |
| `'t'` (0x74) | TYPE_INTERNED | Interned string |
| `'u'` (0x75) | TYPE_UNICODE | UTF-8 string |
| `'a'` (0x61) | TYPE_ASCII | Pure ASCII string |
| `'A'` (0x41) | TYPE_ASCII_INTERNED | Interned ASCII |
| `'z'` (0x7A) | TYPE_SHORT_ASCII | 1-byte length ASCII |
| `'Z'` (0x5A) | TYPE_SHORT_ASCII_INTERNED | Interned short ASCII |

#### Container Types
| Type Code | Name | Description |
|-----------|------|-------------|
| `'('` (0x28) | TYPE_TUPLE | Tuple (u32 length) |
| `')'` (0x29) | TYPE_SMALL_TUPLE | Tuple (u8 length) |
| `'['` (0x5B) | TYPE_LIST | List (u32 length) |
| `'{'` (0x7B) | TYPE_DICT | Dict (key-value pairs until TYPE_NULL) |
| `'<'` (0x3C) | TYPE_SET | Set |
| `'>'` (0x3E) | TYPE_FROZENSET | Frozenset |

#### Special Types
| Type Code | Name | Description |
|-----------|------|-------------|
| `'c'` (0x63) | TYPE_CODE | Code object |
| `'r'` (0x72) | TYPE_REF | Reference to previous object |

### FLAG_REF (0x80)
When `type_byte & 0x80` is set, the object should be added to a reference table for later backreference via TYPE_REF.

### TYPE_LONG Encoding
Arbitrary precision integers use sign-magnitude with 15-bit digits:
```
digit_count: i32 (negative = negative number)
digits: [abs(digit_count)]u16 (base 2^15 digits, little-endian)
```

---

## Code Object Structure

Code objects contain all metadata for a function/module. The field layout varies by version.

### Python 2.3-2.7
```
argcount:     u32    # Positional argument count
nlocals:      u32    # Local variable count
stacksize:    u32    # Max stack depth
flags:        u32    # Code flags
code:         bytes  # Bytecode
consts:       tuple  # Constant pool
names:        tuple  # Global/attribute names
varnames:     tuple  # Local variable names
freevars:     tuple  # Free variable names (closures)
cellvars:     tuple  # Cell variable names
filename:     str    # Source filename
name:         str    # Function name
firstlineno:  u32    # First source line number
lnotab:       bytes  # Line number table
```

### Python 3.0-3.7
```
argcount:       u32
kwonlyargcount: u32    # Keyword-only argument count (NEW)
nlocals:        u32
stacksize:      u32
flags:          u32
code:           bytes
consts:         tuple
names:          tuple
varnames:       tuple
freevars:       tuple
cellvars:       tuple
filename:       str
name:           str
firstlineno:    u32
lnotab:         bytes
```

### Python 3.8-3.10
```
argcount:        u32
posonlyargcount: u32   # Position-only argument count (NEW)
kwonlyargcount:  u32
nlocals:         u32
stacksize:       u32
flags:           u32
code:            bytes
consts:          tuple
names:           tuple
varnames:        tuple
freevars:        tuple
cellvars:        tuple
filename:        str
name:            str
firstlineno:     u32
lnotab:          bytes
```

### Python 3.11+
```
argcount:        u32
posonlyargcount: u32
kwonlyargcount:  u32
stacksize:       u32
flags:           u32
code:            bytes
consts:          tuple
names:           tuple
varnames:        tuple
filename:        str
name:            str
qualname:        str     # Qualified name (NEW)
firstlineno:     u32
linetable:       bytes   # New format (replaces lnotab)
exceptiontable:  bytes   # Exception handler table (NEW)
# freevars/cellvars removed from marshal
# localkinds added (NEW)
```

### Code Flags
| Flag | Value | Description |
|------|-------|-------------|
| CO_OPTIMIZED | 0x0001 | Uses fast locals |
| CO_NEWLOCALS | 0x0002 | New local namespace |
| CO_VARARGS | 0x0004 | Has *args |
| CO_VARKEYWORDS | 0x0008 | Has **kwargs |
| CO_NESTED | 0x0010 | Nested function |
| CO_GENERATOR | 0x0020 | Generator function |
| CO_NOFREE | 0x0040 | No free variables |
| CO_COROUTINE | 0x0080 | Coroutine (3.5+) |
| CO_ITERABLE_COROUTINE | 0x0100 | Iterable coroutine (3.5+) |
| CO_ASYNC_GENERATOR | 0x0200 | Async generator (3.6+) |

---

## Opcode Encoding

### Argument Threshold
Opcodes >= 90 take arguments. Opcodes < 90 are standalone.

### Pre-3.6 Encoding (1-3 bytes)
```
┌──────────┐
│ opcode   │  ← 1 byte (no-arg opcodes)
└──────────┘

┌──────────┬──────────┬──────────┐
│ opcode   │ arg_low  │ arg_high │  ← 3 bytes (arg opcodes)
└──────────┴──────────┴──────────┘
     u8        u8         u8       (arg = low | (high << 8))
```

### 3.6+ Encoding (2 bytes per instruction)
```
┌──────────┬──────────┐
│ opcode   │ arg      │  ← 2 bytes always (word-aligned)
└──────────┴──────────┘
     u8        u8
```

### 3.11+ Encoding (with cache)
```
┌──────────┬──────────┐┌──────────┬──────────┐...
│ opcode   │ arg      ││ CACHE    │ 0x00     │...
└──────────┴──────────┘└──────────┴──────────┘
     instruction            cache entries
```
Cache entries (opcode 0) follow specialized instructions for inline caching.

### EXTENDED_ARG
For arguments > 255 (or > 65535 pre-3.6):
```
EXTENDED_ARG  0x01    # arg = 0x0100
LOAD_CONST    0x34    # final_arg = 0x0134
```
Multiple EXTENDED_ARG can chain for larger values.

---

## Instruction Decoding

### Python 3.11+ Opcodes (Canonical Reference)

#### No-Argument Opcodes (< 90)
| Value | Name | Description |
|-------|------|-------------|
| 0 | CACHE | Adaptive cache slot |
| 1 | POP_TOP | Pop TOS |
| 2 | PUSH_NULL | Push NULL for method calls |
| 4 | END_FOR | End for-loop iteration |
| 9 | NOP | No operation |
| 10 | UNARY_NEGATIVE | TOS = -TOS |
| 11 | UNARY_NOT | TOS = not TOS |
| 12 | UNARY_INVERT | TOS = ~TOS |
| 25 | BINARY_SUBSCR | TOS = TOS1[TOS] |
| 26 | BINARY_SLICE | TOS = TOS2[TOS1:TOS] |
| 27 | STORE_SLICE | TOS2[TOS1:TOS] = TOS3 |
| 30 | GET_LEN | Push len(TOS) |
| 31 | MATCH_MAPPING | Pattern match mapping |
| 32 | MATCH_SEQUENCE | Pattern match sequence |
| 33 | MATCH_KEYS | Pattern match keys |
| 49 | GET_AITER | TOS = TOS.__aiter__() |
| 50 | GET_ANEXT | Push awaitable |
| 51 | BEFORE_ASYNC_WITH | Prepare async with |
| 52 | BEFORE_WITH | Prepare with |
| 53 | END_ASYNC_FOR | End async for |
| 68 | GET_ITER | TOS = iter(TOS) |
| 69 | GET_YIELD_FROM_ITER | Get yield from iterator |
| 71 | LOAD_BUILD_CLASS | Push builtins.__build_class__ |
| 83 | RETURN_VALUE | Return TOS |
| 85 | SETUP_ANNOTATIONS | Initialize annotations |
| 87 | LOAD_LOCALS | Push locals() |
| 89 | POP_EXCEPT | Pop exception handler |

#### Argument Opcodes (>= 90)
| Value | Name | Description |
|-------|------|-------------|
| 90 | STORE_NAME | name[arg] = TOS |
| 91 | DELETE_NAME | del name[arg] |
| 92 | UNPACK_SEQUENCE | Unpack TOS into arg items |
| 93 | FOR_ITER | Iterate or jump arg |
| 94 | UNPACK_EX | Extended unpack with star |
| 95 | STORE_ATTR | TOS.attr[arg] = TOS1 |
| 96 | DELETE_ATTR | del TOS.attr[arg] |
| 97 | STORE_GLOBAL | globals[arg] = TOS |
| 98 | DELETE_GLOBAL | del globals[arg] |
| 99 | SWAP | Swap TOS with stack[arg] |
| 100 | LOAD_CONST | Push consts[arg] |
| 101 | LOAD_NAME | Push names[arg] |
| 102 | BUILD_TUPLE | Build tuple from arg items |
| 103 | BUILD_LIST | Build list from arg items |
| 104 | BUILD_SET | Build set from arg items |
| 105 | BUILD_MAP | Build dict from arg pairs |
| 106 | LOAD_ATTR | Push TOS.attr[arg] |
| 107 | COMPARE_OP | Comparison (see below) |
| 108 | IMPORT_NAME | Import names[arg] |
| 109 | IMPORT_FROM | Import from TOS |
| 110 | JUMP_FORWARD | Jump +arg words |
| 114 | POP_JUMP_IF_FALSE | Pop and jump if false |
| 115 | POP_JUMP_IF_TRUE | Pop and jump if true |
| 116 | LOAD_GLOBAL | Push globals[arg] |
| 117 | IS_OP | Identity test |
| 118 | CONTAINS_OP | Containment test |
| 119 | RERAISE | Re-raise exception |
| 120 | COPY | Copy stack[arg] to TOS |
| 121 | RETURN_CONST | Return consts[arg] |
| 122 | BINARY_OP | Binary operation (see below) |
| 124 | LOAD_FAST | Push locals[arg] |
| 125 | STORE_FAST | locals[arg] = TOS |
| 126 | DELETE_FAST | del locals[arg] |
| 128 | POP_JUMP_IF_NOT_NONE | Pop and jump if not None |
| 129 | POP_JUMP_IF_NONE | Pop and jump if None |
| 130 | RAISE_VARARGS | Raise with arg values |
| 132 | MAKE_FUNCTION | Create function |
| 133 | BUILD_SLICE | Build slice object |
| 136 | LOAD_CLOSURE | Load closure variable |
| 137 | LOAD_DEREF | Load free variable |
| 138 | STORE_DEREF | Store free variable |
| 139 | DELETE_DEREF | Delete free variable |
| 140 | JUMP_BACKWARD | Jump -arg words |
| 142 | CALL_FUNCTION_EX | Call with *args/**kwargs |
| 144 | EXTENDED_ARG | Extend next argument |
| 145 | LIST_APPEND | list.append for comprehension |
| 146 | SET_ADD | set.add for comprehension |
| 147 | MAP_ADD | dict update for comprehension |
| 150 | YIELD_VALUE | Yield TOS |
| 151 | RESUME | Resume generator |
| 152 | MATCH_CLASS | Pattern match class |
| 156 | BUILD_CONST_KEY_MAP | Build dict with const keys |
| 157 | BUILD_STRING | Join arg strings |
| 164 | LIST_EXTEND | Extend list |
| 165 | SET_UPDATE | Update set |
| 166 | DICT_MERGE | Merge dicts |
| 167 | DICT_UPDATE | Update dict |
| 171 | CALL | Call function |
| 172 | KW_NAMES | Set keyword names |

### COMPARE_OP Arguments
| Value | Operator |
|-------|----------|
| 0 | < (LT) |
| 1 | <= (LE) |
| 2 | == (EQ) |
| 3 | != (NE) |
| 4 | > (GT) |
| 5 | >= (GE) |

### BINARY_OP Arguments
| Value | Operator | Inplace (+13) |
|-------|----------|---------------|
| 0 | + | += |
| 1 | & | &= |
| 2 | // | //= |
| 3 | << | <<= |
| 4 | @ | @= |
| 5 | * | *= |
| 6 | % | %= |
| 7 | \| | \|= |
| 8 | ** | **= |
| 9 | >> | >>= |
| 10 | - | -= |
| 11 | / | /= |
| 12 | ^ | ^= |

---

## Control Flow Graph

### Jump Instructions

#### Unconditional Jumps
| Opcode | Type | Target |
|--------|------|--------|
| JUMP_FORWARD | Relative | +arg words |
| JUMP_BACKWARD | Relative | -arg words |
| JUMP_ABSOLUTE | Absolute | arg bytes (pre-3.11) |

#### Conditional Jumps
| Opcode | Condition | Stack Effect |
|--------|-----------|--------------|
| POP_JUMP_IF_FALSE | TOS is false | Pops TOS |
| POP_JUMP_IF_TRUE | TOS is true | Pops TOS |
| POP_JUMP_IF_NONE | TOS is None | Pops TOS |
| POP_JUMP_IF_NOT_NONE | TOS is not None | Pops TOS |
| FOR_ITER | Iterator exhausted | Jumps on exhaustion |

### Basic Block Identification
1. Mark all jump targets as block starts
2. Mark instruction after each jump as block start
3. Mark first instruction as block start
4. Each block runs from start to next boundary

### Exception Table (3.11+)
Format: Variable-length entries
```
start:  varint (relative offset)
end:    varint (relative offset)
target: varint (handler offset)
depth:  varint (stack depth + lasti flag)
```

---

## AST Reconstruction

### Stack Simulation
Python bytecode is stack-based. Reconstruction simulates the stack:

```python
# Source: a + b
LOAD_NAME 'a'     # stack: [a]
LOAD_NAME 'b'     # stack: [a, b]
BINARY_OP ADD     # stack: [a + b]  ← creates BinaryOp node
RETURN_VALUE      # returns stack top
```

### Pattern Recognition

#### Simple Return
```
LOAD_CONST <value>
RETURN_VALUE
```
→ `return <value>`

#### Binary Expression
```
LOAD_* left
LOAD_* right
BINARY_OP <op>
```
→ `left <op> right`

#### Attribute Access
```
LOAD_* object
LOAD_ATTR name
```
→ `object.name`

#### Function Call
```
LOAD_* func
LOAD_* arg1
LOAD_* arg2
...
CALL n
```
→ `func(arg1, arg2, ...)`

#### If Statement
```
LOAD_* condition
POP_JUMP_IF_FALSE else_target
<then_body>
JUMP_FORWARD end_target
else_target:
<else_body>
end_target:
```
→ `if condition: then_body else: else_body`

#### While Loop
```
loop_start:
LOAD_* condition
POP_JUMP_IF_FALSE loop_end
<body>
JUMP_BACKWARD loop_start
loop_end:
```
→ `while condition: body`

#### For Loop
```
LOAD_* iterable
GET_ITER
loop_start:
FOR_ITER loop_end
STORE_FAST var
<body>
JUMP_BACKWARD loop_start
loop_end:
```
→ `for var in iterable: body`

### AST Node Types
| Node | Description |
|------|-------------|
| NODE_OBJECT | Constant value |
| NODE_NAME | Variable reference |
| NODE_UNARY | Unary operation |
| NODE_BINARY | Binary operation |
| NODE_COMPARE | Comparison chain |
| NODE_TERNARY | x if cond else y |
| NODE_TUPLE | Tuple literal |
| NODE_LIST | List literal |
| NODE_SET | Set literal |
| NODE_MAP | Dict literal |
| NODE_SUBSCR | a[b] |
| NODE_SLICE | a[b:c:d] |
| NODE_RETURN | Return statement |
| NODE_FUNCTION | Function definition |
| NODE_CLASS | Class definition |
| NODE_CALL | Function call |
| NODE_COMPREHENSION | Comprehension |
| NODE_IMPORT | Import statement |

---

## Version Differences Summary

### Major Breaking Changes

| Version | Change |
|---------|--------|
| 3.6 | Word-aligned bytecode (2 bytes per instruction) |
| 3.8 | Added posonlyargcount field |
| 3.10 | Pattern matching opcodes |
| 3.11 | Adaptive bytecode with CACHE, exception table, qualname, removed freevars/cellvars from marshal |
| 3.11 | BINARY_OP replaces individual binary opcodes |
| 3.11 | Relative jumps replace absolute jumps |
| 3.11 | linetable replaces lnotab |

### Opcode Renumbering
Opcode values are NOT stable across versions. Each version requires its own mapping table from bytecode values to canonical opcode names.

### Header Evolution
- Pre-3.3: 4-byte header
- 3.3-3.6: 8-byte header
- 3.7+: 12-byte header with flags

### Argument Encoding
- Pre-3.6: 16-bit little-endian arguments
- 3.6+: 8-bit arguments with EXTENDED_ARG chaining

---

## Line Number Tables

Python bytecode maps bytecode offsets to source line numbers. The format evolved significantly.

### co_lnotab (Pre-3.10)

The `co_lnotab` field stores pairs of unsigned bytes: `(bytecode_delta, line_delta)`.

```
┌─────────────────┬─────────────────┐
│ bytecode_delta  │ line_delta      │
└─────────────────┴─────────────────┘
       u8               u8 (signed in 3.8+)
```

**Algorithm to decode:**
```
addr = 0
line = co_firstlineno
for i in range(0, len(co_lnotab), 2):
    addr_incr = co_lnotab[i]
    line_incr = co_lnotab[i+1]
    # Python 3.8+: interpret line_incr as signed
    if version >= 3.8 and line_incr >= 128:
        line_incr = line_incr - 256
    addr += addr_incr
    line += line_incr
    yield (addr, line)
```

**Handling large deltas:**
- If `bytecode_delta > 255`: multiple pairs with `line_delta = 0` until remaining < 256
- If `line_delta > 127` (3.8+): multiple pairs to stay in signed range

### co_linetable (Python 3.10)

Python 3.10 uses a similar format but with signed line deltas:

```
┌─────────────────┬─────────────────┐
│ start_delta     │ line_delta      │
└─────────────────┴─────────────────┘
       u8           i8 (-127 to 127)
```

- **Line delta = -128**: No line number for this range
- Start offset of first entry is always zero
- End of one entry equals start of next

### co_linetable (Python 3.11+)

Python 3.11 uses a complex location table with line AND column information.

**Entry Structure:**
```
┌────────────────────────────────────────┐
│ Header byte (bit 7 always set)         │
├───────┬───────────────┬────────────────┤
│ Bit 7 │ Bits 3-6 (code) │ Bits 0-2 (len-1) │
└───────┴───────────────┴────────────────┘
```

**Location Info Kinds (codes 0-15):**

| Code | Type | Format |
|------|------|--------|
| 0-9 | Short form | 2 bytes total; start_col = code*8 + ((byte2>>4)&7); end_col = start_col + (byte2&15) |
| 10-12 | One line form | line_delta = code - 10; start_col and end_col as u8 bytes |
| 13 | No column | line_delta as svarint; no column data |
| 14 | Long form | All fields as varints: line_delta(svarint), end_line_delta(varint), start_col(varint), end_col(varint) |
| 15 | No location | No source location |

**Variable-length integer encoding:**
- Unsigned (varint): 6-bit chunks, LSB first. Bit 6 set on all but last chunk.
- Signed (svarint): Zigzag encode first: `(-s << 1) | 1` for negative, `s << 1` for non-negative.

**Decoding pseudocode:**
```
def read_varint(data, pos):
    result = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x3F) << shift
        if not (byte & 0x40):  # bit 6 not set = last chunk
            break
        shift += 6
    return result, pos

def decode_svarint(val):
    if val & 1:
        return -(val >> 1)
    return val >> 1
```

**Sources:**
- [CPython Objects/lnotab_notes.txt](https://github.com/python/cpython/blob/main/Objects/lnotab_notes.txt)
- [PEP 626](https://peps.python.org/pep-0626/)
- [CPython InternalDocs/code_objects.md](https://github.com/python/cpython/blob/main/InternalDocs/code_objects.md)
- [CPython Objects/locations.md](https://chromium.googlesource.com/external/github.com/python/cpython/+/refs/tags/v3.11.7/Objects/locations.md)
