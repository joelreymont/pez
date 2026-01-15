---
title: Implement BINARY_* arithmetic opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:36.835297+02:00"
---

Files: src/stack.zig
Change: Implement binary operations for Python <3.11
- BINARY_ADD/SUBTRACT/MULTIPLY/DIVIDE/MODULO/POWER
- BINARY_FLOOR_DIVIDE/TRUE_DIVIDE
- BINARY_LSHIFT/RSHIFT/AND/OR/XOR
- BINARY_MATRIX_MULTIPLY
- Pop 2 operands, create BinOp AST
Verify: Decompile test with x+y, a*b, etc.
