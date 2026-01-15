---
title: Try/except finally clause detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T16:54:46.529683+02:00\""
closed-at: "2026-01-15T16:55:04.115838+02:00"
---

ctrl.zig:880 - Detect finally block (unconditional exec). Use ExceptionTable nested entries (3.11+) or find common successor from all paths (older). Distinguish from else: finally has edges from exception paths. Test: try_except_finally.py with nesting.
