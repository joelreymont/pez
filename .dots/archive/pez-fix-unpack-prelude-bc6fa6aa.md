---
title: Fix unpack prelude
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T14:31:42.290562+02:00\\\"\""
closed-at: "2026-01-18T14:31:49.696490+02:00"
close-reason: completed
---

Full context: src/decompile.zig:833-1045, 9363. Cause: processPartialBlock/processBlockStatements didn't handle UNPACK_SEQUENCE with structured prelude; produced ellipsis instead of tuple unpack. Fix: add handleUnpack helper; use in processBlockWithSimAndSkip, processBlockStatements, processPartialBlock; consume unpack placeholders.
