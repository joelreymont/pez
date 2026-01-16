---
title: Complete async/await opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:26.612170+02:00"
---

Implement GET_AITER, GET_ANEXT, END_ASYNC_FOR, SETUP_ASYNC_WITH, BEFORE_ASYNC_WITH, WITH_EXCEPT_START, GET_AWAITABLE. Separate GET_YIELD_FROM_ITER (yield from) vs GET_AWAITABLE (await). Files: src/stack.zig. Dependencies: none. Verify: async_for.3.7.pyc and async patterns decompile.
