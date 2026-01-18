---
title: sim ctx alloc
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T06:25:16.301205+02:00\\\"\""
closed-at: "2026-01-18T06:29:27.991323+02:00"
close-reason: completed
---

Context: src/stack.zig:445-490, src/decompile.zig:1861-2038, src/stack.zig call sites. Root cause: SimContext init takes single allocator; stack + AST share it. Fix: change SimContext.init(ast_alloc, stack_alloc, code, version), thread through all call sites + tests. Why: enable temp stack alloc reuse while keeping AST in arena.
