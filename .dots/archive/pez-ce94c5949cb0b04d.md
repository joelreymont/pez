---
title: Implement with statements
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-10T06:36:49.317163+02:00\\\"\""
closed-at: "2026-01-10T07:22:01.936731+02:00"
---

File: src/decompile.zig (pattern detection), src/stack.zig (SETUP_WITH, WITH_CLEANUP_*). Opcodes: SETUP_WITH (3.x), WITH_CLEANUP_START/FINISH (3.5+), BEFORE_WITH (2.7). Control flow: SETUP_WITH creates exception block, WITH_CLEANUP in finally. Implementation: 1) Detect with pattern in CFG (SETUP_WITH + exception edge), 2) Extract context manager expr, 3) Extract as-name if STORE follows, 4) Decompile body, 5) Generate with statement. Test: create simple with_stmt.3.11.pyc. Priority: P2-MEDIUM.
