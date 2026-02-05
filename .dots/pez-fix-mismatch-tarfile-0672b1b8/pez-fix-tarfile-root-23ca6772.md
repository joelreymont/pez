---
title: Fix tarfile root cause
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-05T21:25:22.523638+01:00\\\"\""
closed-at: "2026-02-05T22:57:39.821776+01:00"
blocks:
  - pez-locate-tarfile-divergence-240c457c
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for tarfile; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-tarfile-divergence-240c457c; verification: target compare_driver unit semantic_score=1.0.
