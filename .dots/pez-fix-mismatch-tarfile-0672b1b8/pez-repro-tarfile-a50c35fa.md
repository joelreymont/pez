---
title: Repro tarfile
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-05T21:25:22.516723+01:00\\\"\""
closed-at: "2026-02-05T22:28:38.668014+01:00"
close-reason: reproduced with /tmp/pez-tarfile-driver-1.json
blocks:
  - pez-validate-and-commit-384c0fa5
---

Context: tools/compare/compare_driver.py:1, /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/tarfile.pyc; cause: unresolved mismatch in target unit(s); fix: run driver with uv py39 and persist /tmp report+source; deps: pez-validate-and-commit-384c0fa5; verification: new /tmp report for tarfile exists.
