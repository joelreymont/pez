---
title: Test Python 1.5-2.2 decompilation
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:18.453828+02:00"
---

File: Test with refs/pycdc/tests/compiled/*.pyc files
Run pez on Python 1.5-2.2 .pyc files and verify:
- No more 'def (): pass' output
- Correct function signatures appear
- Compare output to pycdc
Dependencies: pez-add-ver-check-e1d1ac20
Verify: for f in refs/pycdc/tests/compiled/*.2.[0-2].pyc; do ./zig-out/bin/pez "$f"; done
