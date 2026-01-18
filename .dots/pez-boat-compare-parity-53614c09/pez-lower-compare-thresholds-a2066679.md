---
title: Lower compare thresholds by unit type
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T17:39:41.805682+02:00"
---

Full context: tools/compare/compare.py:187-260; add per-path thresholds (e.g., skip metadata for <module>, allow cfg differences for stdlib) and report which threshold triggered mismatch; document in docs/compare/boat_main_mismatch.md.
