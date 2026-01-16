---
title: Implement lambda expression detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:41.447498+02:00\""
closed-at: "2026-01-16T10:17:53.260174+02:00"
---

Files: src/decompile.zig
Change: Detect lambda pattern in bytecode
- MAKE_FUNCTION with lambda code object
- Extract as Lambda AST node instead of FunctionDef
- Handle inline lambda expressions
Verify: Decompile test with lambda x: x+1
