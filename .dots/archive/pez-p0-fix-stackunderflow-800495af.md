---
title: "P0: Fix StackUnderflow in exception handlers"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:48:48.616947+02:00\""
closed-at: "2026-01-16T06:53:42.871966+02:00"
---

src/decompile.zig:4402,3504 - Initialize handler stack with 3 exception values (type, value, traceback) that Python pushes on entry. Fixes async_for.3.7.pyc and try_except_finally.2.6.pyc. Spec: Phase 5
