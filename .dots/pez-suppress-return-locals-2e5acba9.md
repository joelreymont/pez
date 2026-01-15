---
title: "Suppress 'return locals()' in Py2.x classes"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:46:45.395698+02:00"
---

src/decompile.zig - Detect LOAD_LOCALS + RETURN_VALUE pattern at end of class body (flags 0x42). Suppress statement generation for this pattern. Test: test_class.2.5.pyc should not output 'return locals()'.
