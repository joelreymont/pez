---
title: Opcode handlers
status: open
priority: 3
issue-type: task
created-at: "2026-01-18T06:54:47.287283+02:00"
---

Full context: src/stack.zig:1615 giant switch in SimContext.simulate. Root cause: monolithic opcode handler mixes versions/semantics. Fix: split into grouped handler fns or dispatch table; share helpers for CALL*/BUILD*; add tests for opcode groups. Why: maintainability + perf.
