---
title: Fix STORE_NAME underflow
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T15:00:49.571444+02:00\\\"\""
closed-at: "2026-01-17T15:17:27.614083+02:00"
close-reason: completed
---

Full context: src/stack.zig:1734-1742 (SimContext.simulate STORE_NAME/STORE_GLOBAL pop); argparse.pyc hits StackUnderflow at STORE_NAME; trace stack seeding/sim to ensure value present or allow lenient unknown when in flow/lenient; add test.
