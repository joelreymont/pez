---
title: Add glob regression
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.630896+01:00"
blocks:
  - pez-fix-glob-root-7239ddaa
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for glob; deps: pez-fix-glob-root-7239ddaa; verification: new regression fails before fix and passes after.
