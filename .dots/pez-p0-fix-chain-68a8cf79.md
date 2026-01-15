---
title: "P0: Fix chain assignment memory leaks"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T21:47:29.220287+02:00"
---

chain_assignment.2.7.pyc, chain_assignment.3.7.pyc leak 5 addresses each in processBlockWithSimAndSkip. No output produced.
