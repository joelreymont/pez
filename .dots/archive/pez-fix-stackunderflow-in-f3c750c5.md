---
title: Fix StackUnderflow in exception handlers
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:46:46.006133+02:00\""
closed-at: "2026-01-16T10:17:14.282707+02:00"
---

src/decompile.zig:4402,3504 - Initialize handler stack with 3 exception values (type,value,traceback) when entering handler. Test: async_for.3.7.pyc and try_except_finally.2.6.pyc should not crash with StackUnderflow at DUP_TOP.
