---
title: Detect else in detectTryPattern <3.11
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T16:55:46.090166+02:00"
---

In src/ctrl.zig:821 detectTryPattern(), for Python <3.11:
Use CFG topology to find else block:
1. Find successors of try body normal exit (non-exception)
2. Exclude handler blocks
3. Check block not reachable from handler exception paths
4. Verify block before finally/exit
5. Store in pattern.else_block
Dependency: pez-detect-else-in-96095120
Test: try_else.2.7.pyc, try_else.3.8.pyc
