---
title: Scratch popN
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T06:54:23.017368+02:00\\\"\""
closed-at: "2026-01-18T07:16:53.599348+02:00"
close-reason: done
---

Full context: src/stack.zig:383-417 popN/valuesToExprs alloc per opcode; root cause: no scratch buffers; fix: add SimContext scratch StackValue/Expr buffers and reuse for popN/popNExprs/valuesToExprs + call args; why: hot-path allocs cause timeouts.
