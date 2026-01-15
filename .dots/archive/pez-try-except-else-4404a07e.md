---
title: Try/except else clause detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T16:54:42.272397+02:00\""
closed-at: "2026-01-15T16:55:04.111866+02:00"
---

ctrl.zig:879 - Detect else block in try/except/else. Use ExceptionTable (3.11+) or CFG topology (older). Find block on normal path after handlers, not finally. Test: try_else.py for 2.7, 3.8, 3.11, 3.14.
