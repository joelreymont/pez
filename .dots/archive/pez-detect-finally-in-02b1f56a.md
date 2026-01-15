---
title: Detect finally in detectTryPattern <3.11
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T16:56:01.248797+02:00\\\"\""
closed-at: "2026-01-15T17:13:45.332142+02:00"
close-reason: implemented detectFinallyBlockLegacy
---

In src/ctrl.zig:821 detectTryPattern(), for Python <3.11:
Find common successor from all paths:
1. Collect normal exit from try body
2. Collect exits from all exception handlers  
3. Find block reachable from ALL paths (intersection of successors)
4. Verify block has predecessors from both normal and exception flows
5. Distinguish from else: finally has exception path edges
6. Store in pattern.finally_block
Dependency: pez-detect-finally-in-f155561c
Test: try_finally.2.7.pyc, try_finally.3.8.pyc
