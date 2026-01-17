---
title: Ternary sim should not throw
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:21:05.175739+02:00\""
closed-at: "2026-01-17T14:21:23.731154+02:00"
close-reason: completed
---

src/decompile.zig:1804-1816 simulateTernaryBranch should catch simulate errors and return null
