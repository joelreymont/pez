---
title: "Phase 6: Implement match statement guards"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:23:51.106306+02:00"
---

src/decompile.zig:3753 - Detect guard pattern after pattern binding: STORE_NAME → LOAD_NAME same_var → comparison → POP_JUMP_IF_FALSE. Extract guard expression and associate with match case .guard field.
