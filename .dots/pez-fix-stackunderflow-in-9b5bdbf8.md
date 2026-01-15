---
title: Fix StackUnderflow in exception handlers
status: open
priority: 1
issue-type: task
created-at: "2026-01-15T18:07:05.040538+02:00"
---

src/decompile.zig:4402 decompileHandlerBody starts with empty stack.
Bug: DUP_TOP at offset 30 in try_except_finally.2.6.pyc fails - stack is empty.
Root cause: Python pushes 3 values (exc_type, exc_value, traceback) when entering handler.
Fix: Initialize handler stack with 3 .unknown markers before decompiling.
Modify decompileHandlerBody to use decompileBlockRangeWithStack with initial stack.
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/try_except_finally.2.6.pyc and async_for.3.7.pyc
