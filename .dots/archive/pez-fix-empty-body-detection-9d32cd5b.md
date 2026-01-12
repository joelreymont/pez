---
title: Fix empty body detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T21:48:52.683667+02:00\""
closed-at: "2026-01-11T21:53:19.503168+02:00"
---

Add 'pass' when loop/if/function body has no statements. Affects: async_for, contains_op, is_op, test_pop_jump_forward_if_true, test_raise_varargs
