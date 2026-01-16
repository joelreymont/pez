---
title: Disassemble with_stmt.3.14.pyc
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:55:03.909262+02:00"
---

Investigation: Understand bytecode.
- python3 -m dis test/corpus_src/with_stmt.py
- Identify cleanup block pattern
- Note stack state at cleanup entry
- Output: bytecode pattern documented
