---
title: Validate and commit tarfile
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.530194+01:00\""
closed-at: "2026-02-05T22:57:39.829250+01:00"
blocks:
  - pez-add-tarfile-regression-4b4df55c
---

Context: zig build test, tools/compare/compare_driver.py:1, tools/compare/compare_suite.py:1; cause: change must be proven and isolated; fix: run tests+suite, commit single fix with jj describe, start next change with jj new; deps: pez-add-tarfile-regression-4b4df55c; verification: committed fix and updated suite stats.
