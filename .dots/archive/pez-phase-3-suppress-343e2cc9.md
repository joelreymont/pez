---
title: "Phase 3: Suppress Python 2.x class 'return locals()'"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:23:49.275483+02:00\""
closed-at: "2026-01-16T10:18:55.873088+02:00"
---

src/decompile.zig - Detect LOAD_LOCALS + RETURN_VALUE at end of Python 2.x class bodies (flags 0x42) and suppress outputting 'return locals()'. Affects test_class.2.5.pyc, test_docstring.2.5.pyc.
