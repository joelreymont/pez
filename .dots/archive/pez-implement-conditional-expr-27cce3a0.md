---
title: Implement conditional expression (ternary)
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:42.674824+02:00\""
closed-at: "2026-01-16T10:19:22.244182+02:00"
---

Files: src/decompile.zig
Change: Detect ternary operator pattern
- POP_JUMP_IF_FALSE with value merge
- Create IfExp AST node (x if cond else y)
Verify: Decompile test with result = a if b else c
