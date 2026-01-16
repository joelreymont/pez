---
title: Initialize exception handler stack with 3 values
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:59:14.464938+02:00\""
closed-at: "2026-01-16T10:18:07.889776+02:00"
---

Files: src/decompile.zig:4402 and src/decompile.zig:3504
Change: When entering exception handler, initialize stack with 3 exception values
- Python pushes (type, value, traceback) when entering handler
- Initialize handler stack: &[_]StackValue{ .unknown, .unknown, .unknown }
- Pass to decompileBlockRangeWithStack or similar
Verify: Decompile try_except_finally.2.6.pyc and async_for.3.7.pyc without StackUnderflow
