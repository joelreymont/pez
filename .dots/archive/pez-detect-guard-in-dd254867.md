---
title: Detect guard in extractMatchCase
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T16:55:16.053350+02:00\""
closed-at: "2026-01-15T16:59:29.126835+02:00"
---

In src/decompile.zig:3740-3752 extractMatchCase(), after extractMatchPattern():
1. Continue simulating block instructions after pattern
2. Detect guard: non-empty stack followed by POP_JUMP_IF_FALSE
3. If found, decompile guard expr from stack state
4. Store in case.guard instead of null
5. Adjust body_block start to after guard jump
Test: run on match_guard.pyc, verify guard expression decompiled.
