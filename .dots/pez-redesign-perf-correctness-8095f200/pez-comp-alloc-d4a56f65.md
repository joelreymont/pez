---
title: comp alloc
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T06:25:20.736146+02:00"
---

Context: src/stack.zig:1303-1435,1576-1590. Root cause: CompBuilder allocations use SimContext allocator; should be temp, not AST. Fix: allocate CompBuilder + its ArrayLists with stack_alloc; ensure deinit uses stack_alloc and expr clones use ast_alloc. Why: prevent arena growth from transient comp state.
