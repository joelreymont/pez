---
title: Detect CFG leaders
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:34:51.670017+02:00\\\"\""
closed-at: "2026-01-18T10:42:09.807852+02:00"
close-reason: completed
---

Refines dot: pez-build-cfg-block-edeb7db4. File: tools/compare/compare.py:130-190. Root cause: no basic blocks. Fix: compute leaders from jump targets + fallthrough + entry, split instructions into blocks.
