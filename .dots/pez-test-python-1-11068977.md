---
title: Test Python 1.x parsing
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:05:10.858232+02:00"
---

After fixing 16-bit fields, test all Python 1.x/2.2 files. Should not output 'def (): pass'. Run: for f in refs/pycdc/tests/compiled/*.1.*.pyc refs/pycdc/tests/compiled/*.2.[012].pyc; do ./zig-out/bin/pez ""; done | grep -v 'def (): pass'
