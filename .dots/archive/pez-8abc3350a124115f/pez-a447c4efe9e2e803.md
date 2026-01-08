---
title: Emit generator expressions in codegen
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T19:17:45.718008+02:00\""
closed-at: "2026-01-08T22:46:33.424147+02:00"
close-reason: completed
blocks:
  - pez-86139bfce9054c08
---

File: src/codegen.zig:198 - writeExpr lacks generator_exp printing. Add generator_exp output with parentheses and comprehension clauses after generator expression detection is in place.
