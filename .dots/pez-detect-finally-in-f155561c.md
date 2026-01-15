---
title: Detect finally in detectTryPattern 3.11+
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T16:55:56.156408+02:00"
---

In src/ctrl.zig:821 detectTryPattern(), for Python 3.11+:
Use ExceptionTable nested structure:
1. Detect exception entries that wrap entire try/except (outer layer)
2. Target of outer entry is finally block
3. Finally has exception edges from all inner paths
4. Store in pattern.finally_block
Test: try_finally.3.11.pyc, try_finally.3.14.pyc
