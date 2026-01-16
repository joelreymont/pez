---
title: Implement LOAD_METHOD/CALL_METHOD opcodes
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:35.914014+02:00\""
closed-at: "2026-01-16T10:17:53.207049+02:00"
---

Files: src/stack.zig
Change: Implement method call optimization for Python 3.7-3.11
- LOAD_METHOD: load method object
- CALL_METHOD: call loaded method
- Create optimized method call AST
Verify: Decompile test with obj.method() calls
