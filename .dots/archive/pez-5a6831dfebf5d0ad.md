---
title: Investigate NotAnExpression root causes
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-10T06:49:30.544309+02:00\""
closed-at: "2026-01-10T06:52:21.264140+02:00"
---

File: src/stack.zig:225, :269. Task: Determine which StackValue variants cause NotAnExpression errors. Method: 1) Add debug print before error in popExpr/valuesToExprs, 2) Run f-string.3.7.pyc, test_calls.3.11.pyc, 3) Log which variants hit error path, 4) Check if they should be exprs or need wrapping. Dependency: None. Output: List of problematic variants + recommended fix. Priority: P0. Time: <20min.
