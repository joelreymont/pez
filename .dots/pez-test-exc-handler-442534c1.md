---
title: Test exception handler decompilation
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:11:06.223387+02:00"
blocks:
  - pez-fix-stackunderflow-in-9b5bdbf8
---

After fix, verify:
- try_except_finally.2.6.pyc decompiles without error
- async_for.3.7.pyc decompiles without error
- Output shows correct try/except structure
Add snapshot tests for both files.
