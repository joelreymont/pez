---
title: Implement generator/yield expression detection
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:41.753162+02:00"
---

Files: src/stack.zig
Change: Implement yield opcodes
- YIELD_VALUE: yield expression
- YIELD_FROM: yield from expression
- GET_YIELD_FROM_ITER: prepare yield from
- Create Yield/YieldFrom AST nodes
Verify: Decompile test with yield x, yield from y
