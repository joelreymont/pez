---
title: [HIGH] decompiler init cost
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T08:40:30.477205+02:00\\\"\""
closed-at: "2026-01-18T20:28:32.637789+02:00"
close-reason: "paused: minions stopped"
---

src/decompile.zig:136; Decompiler.init always builds CFG+Dom+Analyzer+stack_flow for nested code; dominates sample. Add fast path for single-block/no-branch code; lazily build dom/analyzer; cache per-code results.
