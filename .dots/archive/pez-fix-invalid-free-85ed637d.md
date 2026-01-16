---
title: Fix Invalid free in async_for.3.7.pyc
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:50:07.615769+02:00\""
closed-at: "2026-01-16T06:50:35.723119+02:00"
---

src/decompile.zig:3961 - toOwnedSlice on stmts triggers Invalid free. Root cause: ArrayList capacity tracking issue. Trace: decompileStructuredRangeWithStack → decompileBranchRange → decompileIfWithSkip. Priority P0.
