---
title: Fix NotAnExpression errors - add type tracking
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-10T06:35:51.360936+02:00\""
closed-at: "2026-01-10T06:49:35.145915+02:00"
---

File: src/stack.zig:225, :269 (valuesToExprs). Root cause: Stack contains StackValue variants that aren't expressions (e.g., .none, .integer, .string when not wrapped in .constant). When valuesToExprs() encounters non-expr variant, panics. Solution: 1) Add isExpression() check to StackValue, 2) Auto-wrap primitives in constant exprs, or 3) Track value types better during simulation. Test files: f-string.3.7.pyc, test_calls.3.11.pyc, build_const_key_map.3.8.pyc, unpack_assign.3.7.pyc. Priority: P0-CRITICAL. Affects 30% of failures.
