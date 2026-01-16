---
title: Detect guard pattern after binding
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:38.637522+02:00"
---

File: src/decompile.zig:3753 area (from previous dot)
After STORE_NAME (pattern binding), look for:
  LOAD_NAME same_var
  comparison opcodes (COMPARE_OP)
  POP_JUMP_IF_FALSE
This sequence indicates a guard expression
Mark bytecode range for guard extraction
Dependencies: pez-find-match-statement-51d97862
Verify: Read test case bytecode to confirm pattern
