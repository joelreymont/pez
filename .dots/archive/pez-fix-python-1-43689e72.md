---
title: Fix Python 1.5-2.2 marshal parsing
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-15T18:06:41.134959+02:00\\\"\""
closed-at: "2026-01-15T18:12:01.947795+02:00"
close-reason: blocked - need to investigate string/tuple length encoding for Python 2.2
---

src/pyc.zig:868-872 reads 32-bit fields for all Python < 3.0.
Actual format:
- Python 1.3-2.2: 16-bit fields (argcount, nlocals, stacksize, flags)
- Python 2.3+: 32-bit fields
- Python 1.0-1.2: no argcount field
- Python 1.3-1.4: no stacksize field
Fix: Add version checks using ver.gte() for readU16 vs readU32.
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/test_class.2.2.pyc should output class defs, not 'def (): pass'
