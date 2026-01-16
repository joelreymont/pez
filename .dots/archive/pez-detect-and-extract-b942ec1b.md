---
title: Detect and extract class decorators/metaclass
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:40.531075+02:00\""
closed-at: "2026-01-16T10:19:22.231198+02:00"
---

Files: src/decompile.zig
Change: Detect class decorator and metaclass patterns
- Decorators: similar to function decorators
- Metaclass: __build_class__ keyword arg
- Extract and store in ClassDef
Verify: Decompile test with @decorator class Foo(metaclass=M)
