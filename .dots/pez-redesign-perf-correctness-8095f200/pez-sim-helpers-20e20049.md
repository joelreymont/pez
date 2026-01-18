---
title: sim helpers
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T06:25:37.046118+02:00"
---

Context: src/decompile.zig:1861-2038. Root cause: duplicated simulate* helpers with slight behavior drift. Fix: unify into single simulateExpr helper with options (skip, stop_on_cond, stop_on_stmt, stop_on_jump, boolop). Update callers + tests. Why: DRY, consistent semantics.
