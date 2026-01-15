---
title: Detect else in detectTryPattern 3.11+
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T16:55:40.916585+02:00\\\"\""
closed-at: "2026-01-15T17:08:41.551081+02:00"
close-reason: detectElseBlock311 finds L2 (last_try normal succ after handlers, not reachable from handlers). decompileTry311 decompiles else_start..first_handler. Tests pass except memory leak (unrelated).
---

In src/ctrl.zig:821 detectTryPattern(), after handler collection (line 874):
For Python 3.11+, use ExceptionTable to find else block:
1. Identify blocks covered by exception entries
2. Find block after handlers, not in exception coverage
3. Verify block is on normal path from try body
4. Store in pattern.else_block
Test: try_else.3.11.pyc, try_else.3.14.pyc
