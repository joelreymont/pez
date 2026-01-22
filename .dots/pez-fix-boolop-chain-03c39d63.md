---
title: Fix boolop chain compare OR-not
status: open
priority: 2
issue-type: task
created-at: "2026-01-22T11:29:00.697938+02:00"
---

Full context: src/sc_pass.zig simulateBoolOpCondExpr/buildBoolOpExpr. Root cause: boolop builder fails on chained comparison blocks (DUP_TOP+ROT_THREE+JUMP_IF_FALSE_OR_POP) with trailing UNARY_NOT, so detectBoolOp falls back to if and decompiles needsquoting incorrectly. Fix: extend boolop expr building to collapse chained comparisons and unary_not merge blocks. Why: correct short-circuit return expressions (e.g., quopri.needsquoting).
