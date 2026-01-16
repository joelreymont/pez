---
title: Implement FORMAT_VALUE/BUILD_STRING for f-strings
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:38.680289+02:00\""
closed-at: "2026-01-16T10:17:53.239295+02:00"
---

Files: src/stack.zig
Change: Implement f-string opcodes
- FORMAT_VALUE: format single value in f-string
- BUILD_STRING: concatenate formatted parts
- FORMAT_SIMPLE/FORMAT_WITH_SPEC (3.14+)
- Create JoinedStr AST node
Verify: Decompile test with f'x={x}'
