---
title: Debug Python 2.2 LOAD_FAST varnames
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:28:38.980647+02:00\""
closed-at: "2026-01-15T18:35:09.307271+02:00"
---

Files: src/stack.zig:1422-1427
Issue: LOAD_FAST pushes .unknown for Python 2.2, causing NotAnExpression in COMPARE_OP
Test: refs/pycdc/tests/compiled/if_elif_else.2.2.pyc
Add debug output to see if varnames is empty or idx is out of bounds
Verify: pycdas shows varnames=['msgtype','flags'], LOAD_FAST 1 should load 'flags'
