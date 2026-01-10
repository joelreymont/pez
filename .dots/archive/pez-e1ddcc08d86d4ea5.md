---
title: Audit missing opcodes causing StackUnderflow
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-10T06:49:12.660462+02:00\""
closed-at: "2026-01-10T06:52:21.259420+02:00"
---

File: src/stack.zig simulate(). Task: Run failing tests, identify specific unhandled opcodes. Method: 1) Test test_print_to.2.5.pyc with debug output, 2) Test test_for_loop_py3.8.3.10.pyc, 3) Grep simulate() for 'else =>' unhandled cases, 4) List all missing opcodes. Dependency: None. Output: List of specific missing opcodes. Priority: P0. Time: <15min.
