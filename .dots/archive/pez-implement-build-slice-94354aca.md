---
title: Implement BUILD_SLICE opcode
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:39.614532+02:00\""
closed-at: "2026-01-16T10:17:53.249403+02:00"
---

Files: src/stack.zig
Change: Implement slice object creation
- BUILD_SLICE: pop start/stop/step, create slice
- Handle x[start:stop:step]
- Create Slice AST node
Verify: Decompile test with x[1:10:2]
