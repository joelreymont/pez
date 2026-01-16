---
title: Implement BUILD_TUPLE/LIST/SET/MAP opcodes
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:36.220624+02:00\""
closed-at: "2026-01-16T10:17:53.210621+02:00"
---

Files: src/stack.zig
Change: Implement collection building opcodes
- BUILD_TUPLE: pop N items, create tuple
- BUILD_LIST: pop N items, create list
- BUILD_SET: pop N items, create set
- BUILD_MAP: pop 2N items, create dict
Verify: Decompile test with [1,2,3], (1,2), {1,2}, {'a':1}
