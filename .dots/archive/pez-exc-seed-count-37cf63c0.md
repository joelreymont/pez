---
title: Exception seed count
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T12:55:31.801010+02:00\""
closed-at: "2026-01-17T12:55:36.932744+02:00"
close-reason: completed
---

Full context: src/decompile.zig:7756. Cause: blocks with ROT_FOUR/WITH_EXCEPT_START need 4 stack items (exit func + exc triple); seeding always 3 caused underflow (contextlib __exit__). Fix: compute exceptionSeedCount, push 4 when needed in decompileBlock/decompileBlockIntoWithStack.
