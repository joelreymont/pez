---
title: Implement match statement guards
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:29:16.430444+02:00"
---

Files: src/decompile.zig:3753
Pattern: After STORE_NAME binding, detect LOAD_NAME + comparison + POP_JUMP_IF_FALSE
Extract guard expression, wire to MatchCase.guard field
Test: Create test case for 'case y if y > 0:' pattern
Verify: Output shows guard in match case
