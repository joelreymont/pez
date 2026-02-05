---
title: Fix ftplib root cause
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.609397+01:00"
blocks:
  - pez-locate-ftplib-divergence-4b9e171b
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for ftplib; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-ftplib-divergence-4b9e171b; verification: target compare_driver unit semantic_score=1.0.
