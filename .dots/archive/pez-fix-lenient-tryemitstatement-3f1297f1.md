---
title: Fix lenient tryEmitStatement underflow
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:20:58.762295+02:00\""
closed-at: "2026-01-17T14:21:18.846628+02:00"
close-reason: completed
---

src/decompile.zig:286-306 tryEmitStatement throws on empty stack; allow lenient sims to return null instead of StackUnderflow
