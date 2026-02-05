---
title: Add subprocess regression
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.544443+01:00"
blocks:
  - pez-fix-subprocess-root-e28bd5dc
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for subprocess; deps: pez-fix-subprocess-root-e28bd5dc; verification: new regression fails before fix and passes after.
