---
title: Add tarfile regression
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.526898+01:00"
blocks:
  - pez-fix-tarfile-root-23ca6772
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for tarfile; deps: pez-fix-tarfile-root-23ca6772; verification: new regression fails before fix and passes after.
