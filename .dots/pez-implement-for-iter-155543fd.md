---
title: Implement FOR_ITER/GET_ITER opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:37.756166+02:00"
---

Files: src/stack.zig
Change: Implement iteration opcodes
- GET_ITER: pop iterable, push iterator
- FOR_ITER: advance iterator or jump
- GET_AITER/GET_ANEXT: async variants
- Handle for loop control flow
Verify: Decompile test with for x in y:
