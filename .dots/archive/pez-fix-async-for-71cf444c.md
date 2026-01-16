---
title: Fix async_for.3.7.pyc StackUnderflow at offset 112
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T20:23:18.514869+02:00\""
closed-at: "2026-01-16T10:19:16.824951+02:00"
---

Function: time_for_some_fun, DUP_TOP fails with empty stack. Nested async for + regular for + try/except pattern. Need to trace exact block sequence and understand why processBlockStatements has empty stack when it shouldn't. Related: decompileForBody:4789 → processBlockStatements:5066 → simulate DUP_TOP.
