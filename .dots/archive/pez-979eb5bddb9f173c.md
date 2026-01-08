---
title: Support big int constants
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T18:06:33.356894+02:00\""
closed-at: "2026-01-08T19:05:49.305609+02:00"
close-reason: completed
---

File: src/stack.zig:163-166 - objToConstant maps pyc.Int.big to .{ .int = 0 } placeholder. Extend AST constant representation to carry arbitrary precision (likely new ast.Constant.big_int or reuse pyc.BigInt) and update codegen to print correctly. Update objToConstant to convert pyc.Int.big into the new constant form.
