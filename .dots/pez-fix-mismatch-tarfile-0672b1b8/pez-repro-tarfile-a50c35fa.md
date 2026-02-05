---
title: Repro tarfile
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.516723+01:00"
blocks:
  - pez-validate-and-commit-384c0fa5
---

Context: tools/compare/compare_driver.py:1, /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/tarfile.pyc; cause: unresolved mismatch in target unit(s); fix: run driver with uv py39 and persist /tmp report+source; deps: pez-validate-and-commit-384c0fa5; verification: new /tmp report for tarfile exists.
