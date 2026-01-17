---
title: Fix CALL_FUNCTION_KW cleanup
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T13:11:46.261156+02:00\""
closed-at: "2026-01-17T13:11:51.179649+02:00"
close-reason: completed
---

Full context: src/stack.zig:2720-2860. Cause: CALL_FUNCTION_KW error cleanup double-freed/invalid-freed keyword args, causing segfaults. Fix: simplify keyword cleanup, duplicate kw arg names, free original kw_names after loop, and allow unknown callable for KW calls.
