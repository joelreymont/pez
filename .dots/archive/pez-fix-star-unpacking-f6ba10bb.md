---
title: Fix star unpacking
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T07:21:22.119171+02:00\""
closed-at: "2026-01-15T13:29:41.162225+02:00"
close-reason: "UNPACK_EX opcode added to decompile.zig:343, star position extraction and Expr.starred wrapping in simple_name handler at line 392"
---

a, *rest = [...] crashes. Need to handle UNPACK_EX opcode for extended unpacking.
