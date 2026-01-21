---
title: emit min tool
status: open
priority: 2
issue-type: task
created-at: "2026-01-20T13:33:02.650147+02:00"
---

Full context: tools/compare/emit_min.py: shrink source to minimal repro for a unit path. Cause: large decompiled modules slow compare iteration. Fix: ddmin top-level statements while preserving target unit bytecode via unit_diff. Why: fast focused reproduction.
