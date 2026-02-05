---
title: Fix handler range aioice
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:24:29.046309+01:00\""
closed-at: "2026-02-05T22:09:30.624880+01:00"
close-reason: completed
blocks:
  - pez-locate-aioice-divergence-2daa32cc
---

Context: src/decompile.zig:14906, src/decompile.zig:20481; cause: handler body_end truncation and POP_EXCEPT early-stop mis-structures nested try/finally; fix: adjust handler boundary and body traversal to emit original cleanup/return control flow; deps: pez-locate-aioice-divergence-2daa32cc; verification: compare_driver semantic_score=1.0 for <module>.MDnsProtocol.resolve.
