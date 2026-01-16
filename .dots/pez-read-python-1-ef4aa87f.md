---
title: Read Python 1.5-2.2 marshal format
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:05.583813+02:00"
---

File: src/pyc.zig:849-872
Study current readCode implementation and pycdc pyc_code.cpp:5-27 to understand:
- Python 1.3-2.2 uses 16-bit (short) fields for argcount/nlocals/stacksize/flags
- Python 2.3+ uses 32-bit (long) fields
- Python 1.3-1.4 has no stacksize field
- Python 1.0-1.2 has no argcount field
Verify: Read code and document understanding
