---
title: Fix picamera2 controls root cause
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.592326+01:00"
blocks:
  - pez-locate-picamera2-controls-7b714507
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for picamera2 controls; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-picamera2-controls-7b714507; verification: target compare_driver unit semantic_score=1.0.
