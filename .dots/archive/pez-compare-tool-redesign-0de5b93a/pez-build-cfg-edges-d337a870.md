---
title: Build CFG edges
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:34:55.783330+02:00\\\"\""
closed-at: "2026-01-18T10:42:19.604643+02:00"
close-reason: completed
---

Refines dot: pez-build-cfg-block-edeb7db4. File: tools/compare/compare.py:190-240. Root cause: no control-flow structure. Fix: classify terminators (cond/jump/return/raise/for_iter) and add typed edges + fallthrough.
