---
title: Fix Invalid free in try_except_finally.2.6.pyc
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:50:07.921459+02:00\""
closed-at: "2026-01-16T06:50:35.726839+02:00"
---

src/decompile.zig:3961 - Same Invalid free issue as async_for. Trace: decompileStructuredRange → decompileTry → nested decompileTry. Likely same root cause. Priority P0.
