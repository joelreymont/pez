---
title: Validate and commit picamera2 controls
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.598993+01:00\""
closed-at: "2026-02-06T02:42:17.479300+01:00"
close-reason: validated by suite25 and committed parity fixes
blocks:
  - pez-add-picamera2-controls-b5778e26
---

Context: zig build test, tools/compare/compare_driver.py:1, tools/compare/compare_suite.py:1; cause: change must be proven and isolated; fix: run tests+suite, commit single fix with jj describe, start next change with jj new; deps: pez-add-picamera2-controls-b5778e26; verification: committed fix and updated suite stats.
