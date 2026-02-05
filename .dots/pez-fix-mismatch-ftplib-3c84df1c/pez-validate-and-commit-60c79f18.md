---
title: Validate and commit ftplib
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.616354+01:00"
blocks:
  - pez-add-ftplib-regression-ada1efc3
---

Context: zig build test, tools/compare/compare_driver.py:1, tools/compare/compare_suite.py:1; cause: change must be proven and isolated; fix: run tests+suite, commit single fix with jj describe, start next change with jj new; deps: pez-add-ftplib-regression-ada1efc3; verification: committed fix and updated suite stats.
