---
title: Match statement guards
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:48:48.921330+02:00\""
closed-at: "2026-01-16T10:19:16.855549+02:00"
---

src/decompile.zig:3753 - Detect and extract guard expressions from 'case y if y > 0:' bytecode pattern. Look for LOAD_NAME → comparison → POP_JUMP_IF_FALSE after pattern binding. Spec: Phase 6
