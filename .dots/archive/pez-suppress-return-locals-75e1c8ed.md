---
title: "Suppress 'return locals()' in Python 2.x classes"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T08:05:08.108037+02:00\""
closed-at: "2026-01-16T08:07:01.441706+02:00"
---

src/decompile.zig - Detect LOAD_LOCALS + RETURN_VALUE pattern at end of class body (flags 0x42). Suppress statement generation. Test: test_class.2.5.pyc should not output 'return locals()'
