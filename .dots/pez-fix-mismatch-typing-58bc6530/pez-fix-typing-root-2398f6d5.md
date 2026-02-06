---
title: Fix typing root cause
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.575187+01:00\""
closed-at: "2026-02-06T02:41:50.287184+01:00"
close-reason: root fixes committed (a5a10d67,b36e87e8); typing mismatch cleared
blocks:
  - pez-locate-typing-divergence-f34c06b8
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for typing; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-typing-divergence-f34c06b8; verification: target compare_driver unit semantic_score=1.0.
