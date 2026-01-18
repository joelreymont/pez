---
title: Fix elif prelude detection
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T08:11:02.062753+02:00\\\"\""
closed-at: "2026-01-18T08:15:39.981571+02:00"
close-reason: completed
---

Full context: src/ctrl.zig:830 detectIfPattern marks else blocks with prelude STORE_FAST as elif; vpx.py VpxPayloadDescriptor.parse loses assignments, emits 'elif extended' with missing prelude. Cause: elif detection ignores statement ops before conditional jump. Fix: add hasStmtPrelude check (STORE_/DELETE_/IMPORT_/RETURN_/RAISE_/YIELD/POP_TOP) to prevent false elif.
