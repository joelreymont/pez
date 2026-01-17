---
title: [LOW] opcode categories
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T22:12:51.060157+02:00"
---

Full context: src/decompile.zig:133. Cause: isStatementOpcode uses string prefix checks on opcode names per instruction, adding avoidable overhead and hidden coupling to naming. Fix: replace with compile-time opcode category bitset or switch on Opcode values.
