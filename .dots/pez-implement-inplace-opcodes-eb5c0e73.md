---
title: Implement INPLACE_* opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:37.144517+02:00"
---

Files: src/stack.zig
Change: Implement augmented assignment for Python <3.11
- INPLACE_ADD/SUBTRACT/MULTIPLY/etc (13 variants)
- Pop target and value, create AugAssign AST
- Handle x += y, x *= 2, etc.
Verify: Decompile test with x += 1, a *= 2
