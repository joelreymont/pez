---
title: Find exception handler decompilation
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:16.966301+02:00"
---

File: src/decompile.zig:4402 and :3504 (from plan)
Read decompileHandlerBody function
Understand how exception handler blocks are decompiled
Identify where handler stack is initialized
Note: Python pushes 3 values (type, value, traceback) on entry
Verify: Read code and trace handler entry points
