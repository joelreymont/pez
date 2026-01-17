---
title: [HIGH] pattern scan cache
status: open
priority: 2
issue-type: task
created-at: "2026-01-17T08:40:37.113141+02:00"
---

src/ctrl.zig:310-360, 1399; detectPattern recomputes hasWithSetup/isMatchSubjectBlock/hasExceptionEdge by scanning insts per block, O(n^2). Precompute per-block flags in Analyzer.init or CFG build; reuse in detectPattern.
