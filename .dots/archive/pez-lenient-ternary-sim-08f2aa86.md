---
title: Lenient ternary sim
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T13:20:04.585964+02:00\""
closed-at: "2026-01-17T13:20:34.373800+02:00"
close-reason: completed
---

Full context: src/decompile.zig:1885. Cause: initCondSim propagated simulate/popExpr underflows, aborting decompile during ternary detection (dataclasses). Fix: return null on simulate/popExpr failure.
