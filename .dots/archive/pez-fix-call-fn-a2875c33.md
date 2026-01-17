---
title: Fix CALL_FUNCTION_KW test
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T15:02:06.153933+02:00\\\"\""
closed-at: "2026-01-17T15:17:27.626905+02:00"
close-reason: completed
---

Full context: src/stack.zig:5268 test 'stack simulation CALL_FUNCTION_KW error clears moved args' now fails (expected NotAnExpression, got void) after lenient/unknown handling; decide correct behavior and update test or logic; add snapshot if needed.
