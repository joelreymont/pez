---
title: Detect LOAD_LOCALS pattern
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:47.021413+02:00"
---

File: src/decompile.zig (location TBD from previous dot)
Add detection for bytecode pattern:
  LOAD_LOCALS
  RETURN_VALUE (at end of code object)
Check if code object has Python 2.x class flags (0x42)
Dependencies: pez-find-class-body-490fba2b
Verify: Read test_class.2.5.pyc bytecode to confirm pattern
