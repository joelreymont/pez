---
title: Add packaging specifiers regression
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.561516+01:00"
blocks:
  - pez-fix-packaging-specifiers-d9824131
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for packaging specifiers; deps: pez-fix-packaging-specifiers-d9824131; verification: new regression fails before fix and passes after.
