---
title: Fix CALL_FUNCTION underflow
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T15:00:53.633517+02:00\\\"\""
closed-at: "2026-01-17T15:17:27.618914+02:00"
close-reason: completed
---

Full context: src/stack.zig SimContext.simulate CALL_FUNCTION/CALL_FUNCTION_KW underflow; psutil/_pslinux.pyc hits StackUnderflow at CALL_FUNCTION; inspect stack seeding/arg counts and allow unknown args/callee when lenient; add test.
