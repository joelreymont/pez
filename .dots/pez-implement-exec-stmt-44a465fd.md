---
title: Implement EXEC_STMT for Python 2.x
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:43.286046+02:00"
---

Files: src/stack.zig
Change: Add EXEC_STMT opcode handler
- Pop code, globals, locals
- Create Exec AST node
- Python 2.x only
Verify: Decompile Python 2.x test with exec code
