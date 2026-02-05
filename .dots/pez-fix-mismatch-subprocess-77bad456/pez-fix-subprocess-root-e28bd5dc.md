---
title: Fix subprocess root cause
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.540854+01:00"
blocks:
  - pez-locate-subprocess-divergence-756855be
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for subprocess; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-subprocess-divergence-756855be; verification: target compare_driver unit semantic_score=1.0.
