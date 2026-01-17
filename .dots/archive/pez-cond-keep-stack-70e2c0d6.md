---
title: Cond keep stack
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T17:28:57.648500+02:00\\\"\""
closed-at: "2026-01-17T17:29:09.964235+02:00"
close-reason: completed
---

Full context: src/decompile.zig:3669-3725; cause: JUMP_IF_*_OR_POP branches need different stack seeds; fix: clone base_vals with condition expr for branch that keeps value to avoid ROT_TWO underflow.
