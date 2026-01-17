---
title: Allow underflow for seeded blocks
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:24:19.832369+02:00\""
closed-at: "2026-01-17T14:24:28.598818+02:00"
close-reason: completed
---

src/decompile.zig:3296-3304 decompileBlockIntoWithStack should allow underflow when init_stack seeded
