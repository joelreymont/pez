---
title: Exc match edge
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T16:50:17.127213+02:00\\\"\""
closed-at: "2026-01-17T16:50:47.616810+02:00"
close-reason: completed
---

Full context: src/cfg.zig:320-361; cause: JUMP_IF_NOT_EXC_MATCH edge types misclassified; fix: treat jump as conditional_false and fallthrough as conditional_true.
