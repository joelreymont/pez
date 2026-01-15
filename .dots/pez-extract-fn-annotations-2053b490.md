---
title: Extract function annotations and defaults
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:40.837340+02:00"
---

Files: src/stack.zig (MAKE_FUNCTION handler)
Change: Extract annotations and defaults from MAKE_FUNCTION
- Flags indicate presence of defaults/kwdefaults/annotations
- Pop from stack based on flags
- Store in FunctionDef AST
Verify: Decompile test with def foo(x: int = 5) -> str:
