---
title: "Phase 5: Fix StackUnderflow in exception handlers"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:23:50.495203+02:00"
---

src/decompile.zig:4402, :3504 - Initialize handler stack with 3 exception values (type, value, traceback) when entering handler. Fixes async_for.3.7.pyc and try_except_finally.2.6.pyc StackUnderflow at DUP_TOP.
