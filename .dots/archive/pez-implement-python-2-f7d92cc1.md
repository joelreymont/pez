---
title: Implement Python 2.x PRINT_* opcodes
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:42.981964+02:00\""
closed-at: "2026-01-16T10:19:22.247620+02:00"
---

Files: src/stack.zig and src/opcodes.zig
Change: Add Python 2.x print statement opcodes
- PRINT_EXPR: print in REPL
- PRINT_ITEM: print item
- PRINT_ITEM_TO: print to file
- PRINT_NEWLINE: print newline
- PRINT_NEWLINE_TO: print newline to file
- Create Print AST node
Verify: Decompile Python 2.x test with print x, y
