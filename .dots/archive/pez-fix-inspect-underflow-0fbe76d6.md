---
title: Fix inspect underflow
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-17T15:21:05.360562+02:00\""
closed-at: "2026-01-17T15:21:07.805544+02:00"
close-reason: completed
---

Full context: inspect.pyc failed at _finddoc offset 510 ROT_TWO StackUnderflow (src/stack.zig:3394). Cause: processBlockWithSimAndSkip ran with empty stack and lenient false; fix by enabling lenient/allow_underflow when sim stack empty (src/decompile.zig:~760).
