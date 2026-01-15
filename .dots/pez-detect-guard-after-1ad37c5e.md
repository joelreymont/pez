---
title: Detect guard after pattern binding
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:11:18.613347+02:00"
blocks:
  - pez-add-match-statement-31671795
---

In src/decompile.zig:3753 (match case handling):
After STORE_NAME for pattern var, look for sequence:
- LOAD_NAME same_var
- comparison op (COMPARE_OP, LOAD_*, etc)
- POP_JUMP_IF_FALSE
Extract comparison expression as guard.
