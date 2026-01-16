---
title: Implement SETUP_WITH/WITH_CLEANUP for context managers
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:39.299102+02:00\""
closed-at: "2026-01-16T10:17:53.245904+02:00"
---

Files: src/stack.zig and src/decompile.zig
Change: Implement with statement opcodes
- SETUP_WITH: setup context manager
- SETUP_ASYNC_WITH: async context manager
- WITH_CLEANUP*/WITH_EXCEPT_START: cleanup handlers
- BEFORE_WITH: pre-with setup
- Create With AST node
Verify: Decompile test with 'with open(f) as x:'
