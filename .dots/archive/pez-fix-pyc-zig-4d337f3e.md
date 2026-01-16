---
title: Fix pyc.zig 16-bit field reads for Python 1.5-2.2
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:59:13.239565+02:00\""
closed-at: "2026-01-16T10:17:14.290028+02:00"
---

Files: src/pyc.zig:849-872
Change: Add version checks to read 16-bit fields instead of 32-bit for Python 1.5-2.2
- Python 2.3+: readU32() for argcount/nlocals/stacksize/flags
- Python 1.5-2.2: readU16() for all fields
- Python 1.3-1.4: readU16() for argcount/nlocals/flags (no stacksize)
- Python 1.0-1.2: readU16() for nlocals/flags (no argcount)
Verify: zig build test && decompile test_class.1.5.pyc (should not output 'def (): pass')
