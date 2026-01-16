---
title: Add version check for 16-bit fields
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:11.405871+02:00"
---

File: src/pyc.zig:849-872
Change readCode to check Python version:
- ver.gte(2,3): read 32-bit fields (current)
- ver.gte(1,5): read 16-bit fields with readU16()
- ver.gte(1,3): read 16-bit, skip stacksize
- else: read 16-bit, skip argcount and stacksize
Dependencies: pez-read-python-1-ef4aa87f
Verify: zig build test
