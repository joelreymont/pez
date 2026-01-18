---
title: Fix try else detect
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T14:37:00.802502+02:00\\\"\""
closed-at: "2026-01-18T14:37:04.798542+02:00"
close-reason: completed
---

Full context: src/ctrl.zig:1022-1290. Cause: detectElseBlockLegacy accepted jump-only block after try, producing spurious try-else in execute_command. Fix: add jumpOnlyTarget helper and reject jump-only candidates in detectElseBlockLegacy/311.
