---
title: Add ftplib regression
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.612922+01:00\""
closed-at: "2026-02-06T02:50:48.472766+01:00"
close-reason: no dedicated fixture added; suite-level validation used
blocks:
  - pez-fix-ftplib-root-2c2e71e9
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for ftplib; deps: pez-fix-ftplib-root-2c2e71e9; verification: new regression fails before fix and passes after.
