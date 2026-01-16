---
title: Add match statement guard detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:07:11.367149+02:00\""
closed-at: "2026-01-16T10:17:18.611293+02:00"
---

src/decompile.zig:3753 - guards are TODO.
Bytecode pattern: STORE_NAME var, LOAD_NAME var, comparison, POP_JUMP_IF_FALSE
Fix: After pattern binding, detect guard sequence and extract expression.
Associate extracted guard with match case's .guard field.
Test: Create test with 'case x if x > 0:' and verify guard appears in output
