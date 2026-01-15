---
title: Implement MAKE_FUNCTION/MAKE_CLOSURE
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:38.373348+02:00"
---

Files: src/stack.zig
Change: Implement function creation opcodes
- MAKE_FUNCTION: create function from code object
- MAKE_CLOSURE: create closure with free vars
- Extract defaults, annotations, kwdefaults
- Create FunctionDef AST node
Verify: Decompile test with def foo(): pass
