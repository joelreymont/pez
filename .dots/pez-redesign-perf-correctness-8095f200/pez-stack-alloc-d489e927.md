---
title: stack alloc
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T06:25:09.515963+02:00\\\"\""
closed-at: "2026-01-18T06:29:23.028200+02:00"
close-reason: completed
---

Context: src/stack.zig:304-360. Root cause: Stack uses SimContext allocator for both stack buffers and Expr alloc/deinit, forcing arena retention. Fix: split Stack to carry stack_alloc + ast_alloc; use stack_alloc for ArrayList, ast_alloc for Expr creation/deinit in popExpr and StackValue.deinit. Why: avoid arena leak, keep AST lifetime correct.
