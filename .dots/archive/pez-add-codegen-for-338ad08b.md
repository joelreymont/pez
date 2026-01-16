---
title: Add codegen for all missing statement types
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:44.511024+02:00\""
closed-at: "2026-01-16T10:19:22.264389+02:00"
---

Files: src/codegen.zig
Change: Implement codegen for:
- function_def, class_def, for_stmt, while_stmt
- with_stmt, try_stmt, import_stmt, import_from
- global_stmt, nonlocal_stmt, raise_stmt, delete
- print_stmt (Python 2.x)
Each needs proper indentation and formatting
Verify: Round-trip tests for each statement type
