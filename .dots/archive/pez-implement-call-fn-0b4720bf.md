---
title: Implement CALL_FUNCTION/CALL_KW opcodes
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:35.608552+02:00\""
closed-at: "2026-01-16T10:17:53.203149+02:00"
---

Files: src/stack.zig (add CALL_FUNCTION* handlers)
Change: Implement function call opcodes for Python 3.0-3.13
- CALL_FUNCTION: standard calls
- CALL_FUNCTION_VAR: *args
- CALL_FUNCTION_KW: **kwargs
- CALL_FUNCTION_VAR_KW: both
- CALL_KW (3.13+)
- Pop args/kwargs, create Call AST node
Verify: Decompile test with function calls
