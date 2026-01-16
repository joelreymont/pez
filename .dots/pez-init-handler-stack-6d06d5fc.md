---
title: Initialize handler stack with 3 values
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:22.932711+02:00"
---

File: src/decompile.zig:4402 or :3504 (from previous dot)
Before decompiling handler block, initialize stack:
  const exc_stack = &[_]StackValue{ .unknown, .unknown, .unknown };
  try self.decompileBlockRangeWithStack(handler_block, end, exc_stack);
This simulates Python's exception value push
Dependencies: pez-find-exc-handler-ed538371
Verify: zig build test
