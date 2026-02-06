---
title: Validate ftplib and commit
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:50:36.588506+01:00\""
closed-at: "2026-02-06T12:57:06.511142+01:00"
close-reason: validated suite22 + commit 347078de
blocks:
  - pez-add-ftplib-regression-c0c907c4
---

Context: zig build test + compare_driver + compare_suite; cause: require verified parity and commit; fix: run validations, commit with jj describe, then jj new; deps: pez-add-ftplib-regression-c0c907c4; verification: ftplib exact and suite count delta
