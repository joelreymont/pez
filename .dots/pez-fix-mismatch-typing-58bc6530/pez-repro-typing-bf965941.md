---
title: Repro typing
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-05T21:25:22.568248+01:00\\\"\""
closed-at: "2026-02-06T02:41:50.281161+01:00"
close-reason: reproduced and persisted reports in /tmp during typing fixes
blocks:
  - pez-validate-and-commit-4561f563
---

Context: tools/compare/compare_driver.py:1, /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/typing.pyc; cause: unresolved mismatch in target unit(s); fix: run driver with uv py39 and persist /tmp report+source; deps: pez-validate-and-commit-4561f563; verification: new /tmp report for typing exists.
