---
title: Scratch popN
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T06:50:57.931796+02:00"
---

Full context: src/stack.zig:383-417 popN/valuesToExprs alloc per opcode; root cause: no scratch for StackValue/Expr slices; fix: add SimContext scratch buffers and reuse in popN/valuesToExprs/call paths; why: hot-path allocs cause timeouts on boat_main.
