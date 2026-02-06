---
title: Repro ftplib
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.602381+01:00\""
closed-at: "2026-02-06T02:50:48.463546+01:00"
close-reason: repro and reports completed in /tmp
blocks:
  - pez-validate-and-commit-c24b51bf
---

Context: tools/compare/compare_driver.py:1, /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/ftplib.pyc; cause: unresolved mismatch in target unit(s); fix: run driver with uv py39 and persist /tmp report+source; deps: pez-validate-and-commit-c24b51bf; verification: new /tmp report for ftplib exists.
