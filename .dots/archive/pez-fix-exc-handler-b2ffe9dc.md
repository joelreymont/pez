---
title: Fix exception handler StackUnderflow
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:56:51.960761+02:00\""
closed-at: "2026-01-16T06:57:52.928427+02:00"
---

src/decompile.zig:4402,3504 - Initialize handler stack with 3 exception values (type,value,traceback), fixes async_for.3.7.pyc and try_except_finally.2.6.pyc DUP_TOP failures
