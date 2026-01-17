---
title: Rollback ternary
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T17:06:07.994881+02:00\\\"\""
closed-at: "2026-01-17T17:06:13.919805+02:00"
close-reason: completed
---

Full context: src/decompile.zig:1949-2475; cause: initCondSim appends statements during ternary detection even when pattern fails, duplicating prelude; fix: snapshot stmts length and restore on null paths.
