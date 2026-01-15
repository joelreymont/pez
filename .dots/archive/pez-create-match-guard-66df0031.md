---
title: Create match guard test case
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T16:55:09.636993+02:00\""
closed-at: "2026-01-15T16:56:37.994251+02:00"
---

Create /tmp/match_guard.py with:
- Simple guard: case x if x > 0
- Complex guard: case [a, b] if a + b == 10
- Multiple guards in one match
Compile to .pyc for Python 3.10, 3.11, 3.14. Verify bytecode structure (pattern → guard expr → POP_JUMP_IF_FALSE → body).
