---
title: Fix SEND stack validation
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:46:19.636820+02:00\""
closed-at: "2026-01-16T14:07:07.844625+02:00"
---

src/stack.zig:3956: SEND opcode needs 2+ items on stack.
- Current: only checks pop succeeds
- Fix: verify stack.len >= 2 before pop (TOS=value, TOS1=generator)
- Unblocks: async_await.3.14.pyc
- Verify: ./zig-out/bin/pez test/corpus/async_await.3.14.pyc
