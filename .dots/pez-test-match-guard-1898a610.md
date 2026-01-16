---
title: Test match guard implementation
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:49.389049+02:00"
---

File: Create test case for 'case y if y > 0:'
Compile test Python code with match guard to .pyc
Run pez and verify:
- Guard appears in output: 'case y if y > 0:'
- Guard expression is correct
- Compare with pycdc output
Dependencies: pez-extract-guard-expr-23d88880
Verify: python3 -c 'import py_compile; py_compile.compile("test_match_guard.py")' && ./zig-out/bin/pez test_match_guard.pyc
