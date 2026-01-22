---
title: decomp trace
status: open
priority: 2
issue-type: task
created-at: "2026-01-22T10:11:31.820038+02:00"
---

Full context: src/decompile.zig:4520-4700 main loop decisions/branching are opaque; trace is partial. Cause: no deterministic per-block decision+stack snapshot record. Fix: add structured trace emitter capturing per-block entry/exit, chosen pattern, stack_in/out. Why: reproducible debugging.
