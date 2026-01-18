---
title: Normalize operands
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:34:42.011062+02:00\\\"\""
closed-at: "2026-01-18T10:41:46.383682+02:00"
close-reason: completed
---

File: tools/compare/compare.py:60-120. Root cause: args compared literally. Fix: normalize const tokens (type/value hash), name tokens (role), call arity bins, compare op tokens, jump kind tokens.
