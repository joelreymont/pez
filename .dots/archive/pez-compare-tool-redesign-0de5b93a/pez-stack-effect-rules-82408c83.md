---
title: Stack effect rules
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:35:06.239707+02:00\\\"\""
closed-at: "2026-01-18T10:42:46.794130+02:00"
close-reason: completed
---

Refines dot: pez-add-stack-effect-3e549a3b. File: tools/compare/compare.py:260-340. Root cause: oppop/oppush insufficient for CALL/BUILD/MAKE ops. Fix: implement stack delta overrides for variable-arg opcodes and compute per-block max depth.
