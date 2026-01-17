---
title: Allow underflow in exception-seeded sims
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:21:02.497660+02:00\""
closed-at: "2026-01-17T14:21:21.507817+02:00"
close-reason: completed
---

src/decompile.zig:3153,3296 exception-seeded sim needs stack.allow_underflow to avoid handler underflows
