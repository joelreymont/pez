---
title: Fix Python 3.14 decompilation
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T10:22:34.420024+02:00"
---

3.14 bytecode changes cause false match detection (walrus.3.14, with_stmt.3.14) and memory leaks (annotations.3.14, async_await.3.14). Need updated opcode tables and pattern detection. Test corpus: test/corpus/*.3.14.pyc. 7/13 pass currently.
