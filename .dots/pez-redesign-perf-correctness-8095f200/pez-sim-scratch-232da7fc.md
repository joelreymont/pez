---
title: sim scratch
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T06:25:26.385526+02:00"
---

Context: src/decompile.zig:1869-2036. Root cause: simulate* helpers create SimContext with arena each call. Fix: add Decompiler scratch stack allocator (ArenaAllocator reset per call) and helper to init SimContext with ast arena + scratch stack alloc. Why: reduce alloc churn, keep AST lifetime.
