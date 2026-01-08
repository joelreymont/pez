---
title: Detect ternary expressions
status: open
priority: 2
issue-type: task
created-at: "2026-01-07T17:40:26.485821+02:00"
---

File: src/ctrl.zig - Pattern: condition, POP_JUMP_IF_FALSE, true_val, JUMP_FORWARD, false_val. Reconstruct IfExp node.
