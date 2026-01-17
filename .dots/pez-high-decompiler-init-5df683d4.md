---
title: [HIGH] decompiler init cost
status: open
priority: 1
issue-type: task
created-at: "2026-01-17T08:40:30.477205+02:00"
---

src/decompile.zig:136; Decompiler.init always builds CFG+Dom+Analyzer+stack_flow for nested code; dominates sample. Add fast path for single-block/no-branch code; lazily build dom/analyzer; cache per-code results.
