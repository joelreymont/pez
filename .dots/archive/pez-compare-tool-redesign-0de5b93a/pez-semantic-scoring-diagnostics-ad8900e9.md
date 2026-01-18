---
title: Semantic scoring + diagnostics
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:32:45.935298+02:00\\\"\""
closed-at: "2026-01-18T10:43:36.048560+02:00"
close-reason: completed
---

File: tools/compare/compare.py:340-520. Root cause: no actionable mismatch data. Fix: add Jaccard scores for block/edge signatures, tiered verdicts, and per-unit diffs (missing/excess signatures, edge diffs, meta mismatches).
