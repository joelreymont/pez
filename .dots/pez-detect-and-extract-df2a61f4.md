---
title: Detect and extract match statement guards
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:59:14.769641+02:00"
---

Files: src/decompile.zig:3753
Change: After pattern binding in match case, detect guard sequence
- Pattern: STORE_NAME var, LOAD_NAME var, comparison, POP_JUMP_IF_FALSE
- Extract guard expression from bytecode between binding and jump
- Associate with match case's .guard field
Verify: Add test with 'case y if y > 0:' pattern, decompile should show guard
