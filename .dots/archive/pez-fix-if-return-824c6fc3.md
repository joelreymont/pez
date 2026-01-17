---
title: Fix if-return duplication
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T21:45:58.950309+02:00\\\"\""
closed-at: "2026-01-17T21:52:11.640956+02:00"
close-reason: fixed
---

Full context: quopri encodestring emits duplicate return after if; investigate CFG/IfPattern for POP_JUMP_IF_FALSE with then-return fallthrough (quopri.pyc encodestring) and fix decompileIf/findIfChainEnd or CFG merge handling to avoid re-emitting then block.
