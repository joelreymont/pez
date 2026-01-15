---
title: Implement BUILD_*_UNPACK opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:36.529227+02:00"
---

Files: src/stack.zig
Change: Implement unpacking opcodes for *args/**kwargs
- BUILD_TUPLE_UNPACK
- BUILD_LIST_UNPACK
- BUILD_SET_UNPACK
- BUILD_MAP_UNPACK
- BUILD_MAP_UNPACK_WITH_CALL
Verify: Decompile test with [*a, *b], {**d1, **d2}
