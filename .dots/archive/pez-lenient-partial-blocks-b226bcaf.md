---
title: Lenient partial blocks
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T13:00:34.625083+02:00\""
closed-at: "2026-01-17T13:00:39.698528+02:00"
close-reason: completed
---

Full context: src/decompile.zig:8330 and src/stack.zig:3260. Cause: processPartialBlock hit stack manipulation ops (DUP_TOP_TWO/ROT_*) and POP_TOP with empty stack due to missing predecessor seed, causing StackUnderflow in if-condition prelude. Fix: set sim.lenient in processPartialBlock, allow empty POP_TOP when lenient, and add lenient handling for stack-manipulation ops.
