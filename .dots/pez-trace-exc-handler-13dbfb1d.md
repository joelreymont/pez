---
title: Trace exception handler stack state
status: open
priority: 1
issue-type: task
created-at: "2026-01-15T18:11:06.215580+02:00"
blocks:
  - pez-fix-stackunderflow-in-9b5bdbf8
---

Disassemble try_except_finally.2.6.pyc and async_for.3.7.pyc.
Document the bytecode sequence at exception handler entry:
- DUP_TOP expects exception type on stack
- Python pushes (exc_type, exc_value, exc_traceback) on handler entry
Identify exact offsets where StackUnderflow occurs.
