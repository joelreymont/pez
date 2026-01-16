---
title: Initialize exception handler stack
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T08:05:08.724093+02:00\""
closed-at: "2026-01-16T08:07:31.667206+02:00"
---

src/decompile.zig:4402,3504 - decompileHandlerBody starts with empty stack but Python pushes 3 exception values (type, value, traceback). Initialize with 3 .unknown values. Fixes StackUnderflow in async_for.3.7.pyc, try_except_finally.2.6.pyc at DUP_TOP
