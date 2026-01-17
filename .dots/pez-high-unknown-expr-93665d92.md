---
title: [HIGH] unknown expr
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T22:12:55.660438+02:00"
---

Full context: src/stack.zig:201. Cause: Stack.popExpr materializes .unknown as name '__unknown__', polluting AST and hiding analysis failures. Fix: add explicit UnknownExpr node or propagate errors when unknown is consumed; keep unknown values out of codegen.
