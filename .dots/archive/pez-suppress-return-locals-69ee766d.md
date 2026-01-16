---
title: Suppress return locals() in Py2 classes
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:29:05.563295+02:00\""
closed-at: "2026-01-16T10:18:07.839871+02:00"
---

Files: src/decompile.zig statement generation
Issue: Python 2.5 classes show 'return locals()' at end
Pattern: LOAD_LOCALS + RETURN_VALUE in class body (flags 0x42)
Fix: Detect pattern, suppress return statement output
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/test_class.2.5.pyc has no return
