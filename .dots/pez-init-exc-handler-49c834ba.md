---
title: Initialize exception handler stack with 3 values
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:50:25.590050+02:00"
---

Files: src/decompile.zig:4402, src/decompile.zig:3504
Root cause: decompileHandlerBody starts with empty stack, but Python pushes (type, value, traceback) on handler entry.
Fix: Initialize handler stack with 3 .unknown values before decompiling handler block.
Test: ./zig-out/bin/pez tests/compiled/async_for.3.7.pyc and try_except_finally.2.6.pyc should not throw StackUnderflow.
