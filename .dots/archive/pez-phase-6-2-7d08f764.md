---
title: "Phase 6.2: Detect guard pattern"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:48:10.139474+02:00\""
closed-at: "2026-01-16T10:18:55.945768+02:00"
---

src/decompile.zig:3753 - After pattern binding (STORE_NAME), detect LOAD_NAME same_var → comparison → POP_JUMP_IF_FALSE
