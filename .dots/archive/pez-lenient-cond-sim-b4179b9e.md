---
title: Lenient cond sim
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T13:19:05.455370+02:00\""
closed-at: "2026-01-17T13:20:34.369140+02:00"
close-reason: completed
---

Full context: src/decompile.zig:1760-1830. Cause: simulateConditionExpr/simulateBoolOpCondExpr/simulateValueExprSkip propagated stack underflows and aborted decompile (dataclasses). Fix: treat simulate/popExpr failures as null (pattern not matched).
