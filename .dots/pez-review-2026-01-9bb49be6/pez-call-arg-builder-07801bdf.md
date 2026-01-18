---
title: Call arg builder
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T06:54:31.721300+02:00\\\"\""
closed-at: "2026-01-18T07:22:42.255859+02:00"
close-reason: done
---

Full context: src/stack.zig:2210-2330 CALL_METHOD/CALL_FUNCTION* duplicate arg handling + mixed alloc/free (args_with_self stack_alloc/free allocator). Root cause: no shared call-arg builder with ownership rules. Fix: centralize call arg assembly + cleanup, standardize stack_alloc for transient arrays. Why: prevent invalid frees and DRY.
