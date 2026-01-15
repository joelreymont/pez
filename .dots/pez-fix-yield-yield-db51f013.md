---
title: Fix yield/yield from statements
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T07:21:22.090248+02:00"
---

Yield statements completely missing from output. Need to handle YIELD_VALUE and YIELD_FROM opcodes in decompile.zig processBlockWithSimAndSkip.
