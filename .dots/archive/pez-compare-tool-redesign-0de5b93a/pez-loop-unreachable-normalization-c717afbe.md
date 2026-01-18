---
title: Loop + unreachable normalization
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:35:01.089624+02:00\\\"\""
closed-at: "2026-01-18T10:42:29.072244+02:00"
close-reason: completed
---

Refines dot: pez-build-cfg-block-edeb7db4. File: tools/compare/compare.py:240-300. Root cause: CFG noise from dead blocks. Fix: detect back-edges/loops and drop unreachable blocks before signatures.
