---
title: Fix subprocess root cause
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.540854+01:00\""
closed-at: "2026-02-06T00:39:05.082671+01:00"
close-reason: Patched rewriteRetRaiseList to preserve early return when else exists
blocks:
  - pez-locate-subprocess-divergence-756855be
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for subprocess; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-subprocess-divergence-756855be; verification: target compare_driver unit semantic_score=1.0.
