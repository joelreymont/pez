---
title: Fix try/except/finally memory leak
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:51:41.945288+02:00\""
closed-at: "2026-01-16T06:53:42.868146+02:00"
---

src/decompile.zig:3515,3534,3564 - decompileStructuredRange and decompileHandlerBody return owned slices that are leaked. Need to free else_body, final_body, handler.body in decompileTry. See async_for.3.7.pyc gpa error trace.
