---
title: Fix exception handler stack init
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:28:54.558811+02:00"
---

Files: src/decompile.zig:4402, src/decompile.zig:3504
Issue: StackUnderflow in async_for.3.7.pyc, try_except_finally.2.6.pyc
Root cause: Handler starts with empty stack but Python pushes 3 exc values
Fix: Initialize with [.unknown, .unknown, .unknown] when entering handler
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/async_for.3.7.pyc succeeds
