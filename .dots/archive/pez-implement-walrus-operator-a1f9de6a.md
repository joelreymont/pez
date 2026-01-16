---
title: Implement walrus operator detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:42.366082+02:00\""
closed-at: "2026-01-16T10:19:22.239980+02:00"
---

Files: src/decompile.zig
Change: Detect named expression pattern
- STORE_NAME/STORE_FAST followed by LOAD of same var
- Create NamedExpr AST node (x := value)
- Python 3.8+ only
Verify: Decompile test with if (x := foo()):
