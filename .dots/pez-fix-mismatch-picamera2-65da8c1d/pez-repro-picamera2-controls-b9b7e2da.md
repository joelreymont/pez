---
title: Repro picamera2 controls
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.585507+01:00\""
closed-at: "2026-02-06T02:42:17.467242+01:00"
close-reason: repro/lower-level analysis previously completed
blocks:
  - pez-validate-and-commit-aa8f0e14
---

Context: tools/compare/compare_driver.py:1, /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/picamera2/controls.pyc; cause: unresolved mismatch in target unit(s); fix: run driver with uv py39 and persist /tmp report+source; deps: pez-validate-and-commit-aa8f0e14; verification: new /tmp report for picamera2 controls exists.
