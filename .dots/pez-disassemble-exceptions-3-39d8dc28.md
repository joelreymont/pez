---
title: Disassemble exceptions.3.14.pyc
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:55:14.641526+02:00"
---

Investigation: Understand bytecode.
- python3 -m dis test/corpus_src/exceptions.py
- Find BINARY_OP at offset 8
- Trace block boundaries around it
- Output: block structure documented
