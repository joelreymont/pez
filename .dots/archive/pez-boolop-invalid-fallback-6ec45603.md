---
title: BoolOp invalid fallback
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T13:15:23.262862+02:00\""
closed-at: "2026-01-17T13:15:27.792442+02:00"
close-reason: completed
---

Full context: src/decompile.zig:2680. Cause: buildBoolOpExpr errors (InvalidBlock) bubbled and aborted decompile (calendar/datetime). Fix: catch InvalidBlock in tryDecompileBoolOpInto and fall back to normal processing.
