---
title: Fix double-free in while loop exit handling
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:55:48.895977+02:00"
---

Files: src/decompile.zig:2520
Bug: Invalid free panic in while_loop.2.6.pyc during exit block decompilation.
decompileBlockRangeWithStack returns owned slice, but caller calls defer free on it before appendSlice which takes ownership.
Fix: Remove defer free at line 2520 - appendSlice already handles ownership.
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/while_loop.2.6.pyc should not panic.
