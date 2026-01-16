---
title: Implement match statement guards
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:46:46.313056+02:00\""
closed-at: "2026-01-16T10:17:18.619396+02:00"
---

src/decompile.zig:3753 - Detect guard pattern: after pattern binding (STORE_NAME), look for LOAD_NAME same_var → comparison → POP_JUMP_IF_FALSE. Extract guard expression and populate match case .guard field.
