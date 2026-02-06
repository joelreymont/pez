---
title: Fix glob root cause
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.627420+01:00\""
closed-at: "2026-02-06T09:32:11.421245+01:00"
close-reason: fixed nested elif merge propagation and loop continue inversion parity
blocks:
  - pez-locate-glob-divergence-b478bd9d
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for glob; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-glob-divergence-b478bd9d; verification: target compare_driver unit semantic_score=1.0.
