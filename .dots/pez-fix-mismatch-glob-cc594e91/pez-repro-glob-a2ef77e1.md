---
title: Repro glob
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-05T21:25:22.620199+01:00\\\"\""
closed-at: "2026-02-06T09:32:11.413736+01:00"
close-reason: reproduced with compare_driver and locate_mismatch
blocks:
  - pez-validate-and-commit-60c79f18
---

Context: tools/compare/compare_driver.py:1, /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/glob.pyc; cause: unresolved mismatch in target unit(s); fix: run driver with uv py39 and persist /tmp report+source; deps: pez-validate-and-commit-60c79f18; verification: new /tmp report for glob exists.
