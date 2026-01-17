---
title: Cond jump exc
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T17:10:56.492140+02:00\\\"\""
closed-at: "2026-01-17T17:11:05.298445+02:00"
close-reason: completed
---

Full context: src/ctrl.zig:807-816, 2138-2148; cause: JUMP_IF_NOT_EXC_MATCH not treated as conditional jump so handler body picked wrong block; fix: include in isConditionalJump and test.
