---
title: Try exit
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T16:50:10.742558+02:00\\\"\""
closed-at: "2026-01-17T16:50:35.258019+02:00"
close-reason: completed
---

Full context: src/decompile.zig:4220-4384; cause: try/except exit/handler bounds mis-handle jump-only exit and POP_EXCEPT boundaries; fix: resolve jump-only exit, scan handler body to POP_EXCEPT, gate finally block.
