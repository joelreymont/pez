---
title: Fix Invalid free panic in stack cleanup
status: open
priority: 2
issue-type: task
created-at: "2026-01-10T06:35:43.803149+02:00"
---

File: src/stack.zig:225, src/decompile.zig:1586, src/stack.zig:269. Root cause: Error paths in popExpr/valuesToExprs trigger cleanup on values not owned by stack. When returning NotAnExpression error, stack values get freed twice. Solution: Add ownership tracking or use arena for temp values in error paths. Test: test_global.2.5.pyc, op_precedence.2.7.pyc, test_kwnames.3.11.pyc. Priority: P0-CRITICAL. Affects 40% of failures.
