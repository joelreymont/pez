---
title: Try else end
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T17:16:37.389185+02:00\\\"\""
closed-at: "2026-01-17T17:16:46.400970+02:00"
close-reason: completed
---

Full context: src/decompile.zig:4305-4318; cause: else_end initialized to handler_start, dropping else blocks that appear after handlers; fix: start else_end at effective_exit and clamp by handler/final/join blocks.
