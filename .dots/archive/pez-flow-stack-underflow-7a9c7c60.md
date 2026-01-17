---
title: Flow stack underflow
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T12:43:26.752016+02:00\""
closed-at: "2026-01-17T12:43:35.938330+02:00"
close-reason: completed
---

Full context: src/stack.zig:322, src/decompile.zig:560. Cause: stack flow analysis aborted on underflow/NotAnExpression, leaving stack_in null for many blocks; later decompile underflowed in partial blocks. Fix: add Stack.allow_underflow for flow_mode, return unknowns in pop/popN/popExpr/valuesToExprs, and enable allow_underflow during initStackFlow.
