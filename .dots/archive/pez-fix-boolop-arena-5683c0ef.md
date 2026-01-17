---
title: Fix boolop arena free
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T12:48:59.762469+02:00\""
closed-at: "2026-01-17T12:49:02.802308+02:00"
close-reason: completed
---

Full context: src/decompile.zig:2669. Cause: tryDecompileBoolOpInto errdefer freed arena-allocated expr from cond_sim (self.arena), causing Invalid free panic. Fix: remove errdefer/free for first expr.
