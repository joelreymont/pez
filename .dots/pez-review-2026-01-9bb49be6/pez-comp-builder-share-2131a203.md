---
title: Comp builder share
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T06:54:38.851996+02:00"
---

Full context: src/stack.zig:1310-1356 cloneCompBuilder deep-copies exprs/generators. Root cause: mutable builder cloned on merges. Fix: make builder immutable with sharing or re-simulate comprehension body from cached slice. Why: avoid exponential clone cost in nested comps.
