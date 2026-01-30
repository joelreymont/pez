---
title: [HIGH] merge-phi
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.499890+01:00"
---

Full context: src/decompile.zig:1968-2033; cause: mergeStackEntry collapses mismatches to .unknown; fix: implement phi/conditional merge representation and emit; add tests.
