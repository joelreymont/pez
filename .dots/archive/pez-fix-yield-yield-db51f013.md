---
title: Fix yield/yield from statements
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T07:21:22.090248+02:00\\\"\""
closed-at: "2026-01-15T09:54:38.185947+02:00"
close-reason: working correctly
---

Yield statements completely missing from output. Need to handle YIELD_VALUE and YIELD_FROM opcodes in decompile.zig processBlockWithSimAndSkip.
