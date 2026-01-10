---
title: Fix StackUnderflow - add missing opcode simulation
status: open
priority: 2
issue-type: task
created-at: "2026-01-10T06:35:59.090757+02:00"
---

File: src/stack.zig:219 (popExpr), :241 (popN). Root cause: Opcodes not handled in simulate() so stack depth tracking breaks. Common missing: Python 2.x PRINT_ITEM/PRINT_NEWLINE, Python 3.8+ GET_ITER variants. Solution: 1) Audit stack.zig simulate() for unhandled opcodes, 2) Add stack effect tracking for each, 3) Implement or stub handlers. Test files: test_print_to.2.5.pyc, test_for_loop_py3.8.3.10.pyc. Priority: P0-CRITICAL. Affects 20% of failures.
