---
title: Read BUILD_CONST_KEY_MAP handler
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:24.430413+02:00"
---

File: src/stack.zig:3466
Study current implementation of BUILD_CONST_KEY_MAP:
- Understand keys_val stack value handling
- Identify why tuple check fails (keys_val.expr.* == .tuple)
- Note: keys_val is StackValue, needs proper tagged union switch
Verify: Read code and identify bug pattern
