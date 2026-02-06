---
title: Fix packaging specifiers root cause
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.558030+01:00\""
closed-at: "2026-02-06T01:53:54.215382+01:00"
close-reason: Implemented in src/decompile.zig with targeted control-flow rewrites; packaging/specifiers.pyc compare_driver now exact 59/59.
blocks:
  - pez-locate-packaging-specifiers-6ece7170
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for packaging specifiers; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-packaging-specifiers-6ece7170; verification: target compare_driver unit semantic_score=1.0.
