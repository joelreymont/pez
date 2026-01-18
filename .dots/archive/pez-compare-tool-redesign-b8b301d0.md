---
title: Compare tool redesign
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-18T09:06:41.066925+02:00\""
closed-at: "2026-01-18T10:54:00.662526+02:00"
close-reason: superseded
---

Full context: tools/compare/compare.py, tools/compare/compare_dir.py, tools/compare/decompile_dir.py. Cause: current sequence/Jaccard metrics produce many false mismatches; need CFG+semantic comparison to measure decomp correctness and give actionable diffs. Fix: design new compare pipeline (normalize, CFG/stack invariants, semantic hashes, diagnostics, thresholds).
