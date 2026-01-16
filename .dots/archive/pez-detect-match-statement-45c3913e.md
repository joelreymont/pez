---
title: Detect match statement guards
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T08:05:09.032227+02:00\""
closed-at: "2026-01-16T08:21:41.647237+02:00"
---

src/decompile.zig:3753 - After pattern binding (STORE_NAME), detect guard pattern: LOAD_NAME same_var → COMPARE_OP → POP_JUMP_IF_FALSE. Extract guard expr from bytecode, set match_case.guard field. Pattern: COPY 1, STORE_NAME y, LOAD_NAME y, comparison, jump
