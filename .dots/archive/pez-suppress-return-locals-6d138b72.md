---
title: Suppress return locals() in Python 2.x classes
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:50:15.600217+02:00\""
closed-at: "2026-01-16T10:18:07.861969+02:00"
---

Files: src/decompile.zig (statement generation)
Pattern: LOAD_LOCALS + RETURN_VALUE at end of class body (flags 0x42).
Detect this pattern and skip outputting 'return locals()' statement.
Test: ./zig-out/bin/pez tests/compiled/test_class.2.5.pyc should not show 'return locals()' at class end.
