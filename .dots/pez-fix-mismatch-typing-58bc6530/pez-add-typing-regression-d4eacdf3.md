---
title: Add typing regression
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.578674+01:00\""
closed-at: "2026-02-06T02:41:50.289981+01:00"
close-reason: no new regression fixture added; superseded by parity-driven validation
blocks:
  - pez-fix-typing-root-2398f6d5
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for typing; deps: pez-fix-typing-root-2398f6d5; verification: new regression fails before fix and passes after.
