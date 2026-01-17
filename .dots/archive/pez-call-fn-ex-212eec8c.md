---
title: CALL_FUNCTION_EX accept unknown args
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:32:39.469021+02:00\""
closed-at: "2026-01-17T14:32:43.788136+02:00"
close-reason: completed
---

src/stack.zig:2841-2907 treat unknown/non-expr args/kwargs/callee as __unknown__ when lenient/flow_mode to avoid NotAnExpression
