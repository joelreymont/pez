---
title: Test all Python 2.2 files pass
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:28:49.569110+02:00"
---

Depends: pez-fix-python-2-a5a69d03
Test: for f in refs/pycdc/tests/compiled/*.2.2.pyc; do ./zig-out/bin/pez "$f" 2>&1 | grep -q error && echo "$f"; done
Should output nothing (all 25 files pass)
Verify: Compare output with pycdc for sample files
