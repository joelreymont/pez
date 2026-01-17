---
title: Handle unknown call
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T12:43:31.536310+02:00\""
closed-at: "2026-01-17T12:43:35.943218+02:00"
close-reason: completed
---

Full context: src/stack.zig:1070. Cause: SimContext.handleCall returned NotAnExpression when callable was .unknown in loop partial blocks, aborting decompilation. Fix: treat .unknown callable as __unknown__ expr and build call expression.
