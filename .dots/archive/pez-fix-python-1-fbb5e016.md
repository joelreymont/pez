---
title: Fix Python 1.3-1.4 firstlineno read
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:10:32.229265+02:00\""
closed-at: "2026-01-16T10:17:14.258771+02:00"
blocks:
  - pez-fix-python-1-43689e72
---

src/pyc.zig:943-946 reads firstlineno as u16 for Python 1.3-1.4.
But pycdc shows firstlineno was u32 starting from 1.5, and 1.3-1.4 had NO lnotab.
Verify against pycdc pyc_code.cpp:24-25.
Test: Check if 1.3/1.4 pyc files exist in refs/pycdc/tests/compiled/
