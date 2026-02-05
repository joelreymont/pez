---
title: Repro packaging specifiers
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-05T21:25:22.551177+01:00\\\"\""
closed-at: "2026-02-06T01:00:57.662529+01:00"
close-reason: Reproduced with uv py39 and captured compare artifacts in /tmp/packaging_specifiers.repro23.json and /tmp/packaging_specifiers.after6.json.
blocks:
  - pez-validate-and-commit-03e5b51c
---

Context: tools/compare/compare_driver.py:1, /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/packaging/specifiers.pyc; cause: unresolved mismatch in target unit(s); fix: run driver with uv py39 and persist /tmp report+source; deps: pez-validate-and-commit-03e5b51c; verification: new /tmp report for packaging specifiers exists.
