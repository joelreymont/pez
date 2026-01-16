---
title: Detect match guard pattern after binding
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:50:32.249805+02:00\""
closed-at: "2026-01-16T10:18:07.873870+02:00"
---

Files: src/decompile.zig:3753
Pattern: STORE_NAME var → LOAD_NAME var → comparison → POP_JUMP_IF_FALSE.
Detection: After pattern binding, check if next instructions match guard sequence.
Extract guard expression between binding and conditional jump.
Associate with MatchCase.guard field.
Test: Create match_guard.3.10.pyc with 'case y if y > 0:', verify guard in output.
