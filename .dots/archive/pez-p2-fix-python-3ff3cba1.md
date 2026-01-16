---
title: "P2: Fix Python 1.5-2.2 marshal parsing"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:48:47.404844+02:00\""
closed-at: "2026-01-16T10:19:16.851587+02:00"
---

src/pyc.zig:849-872 - Replace 32-bit field reads with version-conditional 16-bit reads for argcount/nlocals/stacksize/flags in Python 1.3-2.2. Spec: ~/.claude/plans/bright-kindling-plum.md Phase 1
