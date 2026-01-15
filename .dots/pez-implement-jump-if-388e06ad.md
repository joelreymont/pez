---
title: Implement JUMP_IF_*_OR_POP for short-circuit
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:41.141947+02:00"
---

Files: src/decompile.zig
Change: Detect short-circuit boolean operations
- JUMP_IF_FALSE_OR_POP: and operator
- JUMP_IF_TRUE_OR_POP: or operator
- Create BoolOp AST node
Verify: Decompile test with x and y, a or b
