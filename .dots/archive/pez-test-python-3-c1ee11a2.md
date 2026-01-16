---
title: Test Python 3.10 exception table
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:01:08.488668+02:00\""
closed-at: "2026-01-16T10:19:16.809012+02:00"
---

Files: test suite for Python 3.10 exception handling
Change: Verify exception table parsing for Python 3.10
- 3.11+ uses exceptiontable format
- 3.10 may use different format
- Test nested try/except/finally in 3.10
Verify: Python 3.10 exception tests decompile correctly
