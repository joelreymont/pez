---
title: Detect and extract function decorators
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:40.226715+02:00\""
closed-at: "2026-01-16T10:19:22.226710+02:00"
---

Files: src/decompile.zig
Change: Detect decorator pattern in bytecode
- LOAD_NAME decorator, CALL_FUNCTION, chain
- Extract decorator expressions before MAKE_FUNCTION
- Store in FunctionDef.decorator_list
Verify: Decompile test with @decorator def foo()
