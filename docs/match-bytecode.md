# Match Statement Bytecode Patterns (Python 3.10+)

## Opcodes

- `MATCH_SEQUENCE` - Test if subject is a sequence, push bool
- `MATCH_MAPPING` - Test if subject is a mapping, push bool
- `MATCH_KEYS` - Match mapping keys, push values tuple or None
- `MATCH_CLASS` - Match class pattern, push attrs tuple or None

## Pattern Types

### Literal Match
```python
case 1:
```
Bytecode: `COPY, LOAD_CONST, COMPARE_OP(==), POP_JUMP_IF_FALSE`

### Sequence Match
```python
case [a, b]:
```
Bytecode:
1. `MATCH_SEQUENCE` - test if sequence
2. `POP_JUMP_IF_FALSE` - skip if not
3. `GET_LEN` - get length
4. `LOAD_SMALL_INT n, COMPARE_OP(==)` - check length
5. `POP_JUMP_IF_FALSE` - skip if wrong length
6. `UNPACK_SEQUENCE` - unpack elements
7. `STORE_FAST...` - bind variables

### Mapping Match
```python
case {'a': a, 'b': b}:
```
Bytecode:
1. `MATCH_MAPPING` - test if mapping
2. `POP_JUMP_IF_FALSE` - skip if not
3. `GET_LEN, COMPARE_OP(>=)` - check has enough keys
4. `LOAD_CONST(keys_tuple), MATCH_KEYS` - extract values
5. `POP_JUMP_IF_NONE` - skip if keys missing
6. `UNPACK_SEQUENCE, STORE_FAST...` - bind variables

### Class Match
```python
case Point(x, y):
```
Bytecode:
1. `LOAD_GLOBAL(class)` - load class
2. `LOAD_CONST(attr_names)` - load attribute names
3. `MATCH_CLASS n` - match and extract n positional attrs
4. `POP_JUMP_IF_NONE` - skip if no match
5. `UNPACK_SEQUENCE, STORE_FAST...` - bind variables

### Guard
```python
case n if n > 0:
```
Uses `STORE_FAST_LOAD_FAST` to bind and immediately load for guard test.

### Or Pattern
```python
case 1 | 2 | 3:
```
Compiles to separate comparison chains, each with duplicated body.

### Wildcard
```python
case _:
```
Compiles to just `NOP` (always matches).

## Detection Strategy

1. Look for initial `COPY` or `MATCH_*` opcode after subject load
2. Detect conditional jumps that form case branches
3. Track `STORE_FAST` bindings for pattern variables
4. Match bodies are between successful pattern match and next case

## CFG Structure

Match statements create blocks:
- Condition block per case (pattern test)
- Body block per case
- Fallthrough to next case on pattern failure
- Final wildcard case (if any) as default
