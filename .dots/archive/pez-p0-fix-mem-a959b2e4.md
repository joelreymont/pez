---
title: "P0: Fix memory leaks in exception handlers"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T21:47:25.789474+02:00\""
closed-at: "2026-01-15T22:10:07.281637+02:00"
---

async_for.3.7.pyc, try_except_finally.2.6.pyc leak memory in exception handler decompilation. Was StackUnderflow, now leaks during processBlockWithSimAndSkip.
