---
title: Implement DELETE_SUBSCR opcode
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:43.897980+02:00\""
closed-at: "2026-01-16T10:19:22.257778+02:00"
---

Files: src/stack.zig
Change: Add DELETE_SUBSCR handler
- Pop index and object
- Create Delete AST node with Subscript target
- Handle del x[i]
Verify: Decompile test with del x[0]
