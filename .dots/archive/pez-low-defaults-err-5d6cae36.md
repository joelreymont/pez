---
title: [LOW] defaults-error-mask
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T21:33:03.104934+02:00\""
closed-at: "2026-01-16T22:04:39.814886+02:00"
close-reason: completed
---

Full context: src/stack.zig:2824 swallows allocation errors when collecting function defaults, silently dropping defaults. Fix: propagate error or fail decompile with context; ensure cleanup of partial defaults list.
