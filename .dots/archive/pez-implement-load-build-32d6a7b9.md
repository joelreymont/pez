---
title: Implement LOAD_BUILD_CLASS for class definitions
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:39.920448+02:00\""
closed-at: "2026-01-16T10:17:53.252721+02:00"
---

Files: src/stack.zig
Change: Implement class building opcodes
- LOAD_BUILD_CLASS: load __build_class__
- BUILD_CLASS (Python 2.x): old-style class
- Extract bases, metaclass, decorators
- Create ClassDef AST node
Verify: Decompile test with class Foo: pass
