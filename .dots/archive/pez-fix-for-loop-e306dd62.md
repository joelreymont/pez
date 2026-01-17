---
title: Fix for-loop setup seed
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T12:31:15.527152+02:00\""
closed-at: "2026-01-17T12:31:19.312211+02:00"
close-reason: completed
---

Full context: src/decompile.zig:7806. Cause: iter_sim in decompileFor starts with empty stack, so setup blocks with UNPACK_SEQUENCE before GET_ITER underflow in nested loops. Fix: seed iter_sim with stack_in[setup_block] cloned values before simulating setup instructions.
