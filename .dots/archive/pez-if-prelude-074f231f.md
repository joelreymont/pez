---
title: If prelude
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T16:50:13.947566+02:00\\\"\""
closed-at: "2026-01-17T16:50:40.880437+02:00"
close-reason: completed
---

Full context: src/decompile.zig:7204-7244, 8731-8783; cause: pre-condition statements in if blocks dropped at module level; fix: process partial block with stop_idx and decompileIfWithSkip to emit prelude.
