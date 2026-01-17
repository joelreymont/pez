---
title: Fix RETURN_VALUE underflow
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T15:00:56.509775+02:00\\\"\""
closed-at: "2026-01-17T15:17:27.622944+02:00"
close-reason: completed
---

Full context: src/decompile.zig:8300+ and src/stack.zig RETURN_VALUE handling; runpy.pyc hits StackUnderflow at RETURN_VALUE; ensure stack seeded before return or allow lenient unknown/implicit None; add test.
