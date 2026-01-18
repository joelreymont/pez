---
title: Fix boat_main DUP_TOP underflow
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T20:53:47.999511+02:00\""
closed-at: "2026-01-18T20:55:23.899932+02:00"
close-reason: "done: no repro; decompile_dir ok"
---

Full context: src/stack.zig:2952 DUP_TOP StackUnderflow when decompiling /Users/joel/Work/Shakhed/boat_main_extracted_3.9/boat_main.pyc (offset 98). Cause: block init/sim stack missing TOS before DUP_TOP in decompileIf/decompileStructuredRange. Fix: ensure correct stack initialization or simulate path before DUP_TOP so stack has value; add test case based on boat_main.pyc pattern.
