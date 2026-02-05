---
title: Repro subprocess
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-05T21:25:22.533788+01:00\\\"\""
closed-at: "2026-02-06T00:07:24.455399+01:00"
close-reason: implemented+committed in 3e698c4c; subprocess setcomp exact
blocks:
  - pez-validate-and-commit-ad7f1b7f
---

Context: tools/compare/compare_driver.py:1, /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/subprocess.pyc; cause: unresolved mismatch in target unit(s); fix: run driver with uv py39 and persist /tmp report+source; deps: pez-validate-and-commit-ad7f1b7f; verification: new /tmp report for subprocess exists.
