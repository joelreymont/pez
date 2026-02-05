---
title: Add subprocess regression
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.544443+01:00\""
closed-at: "2026-02-06T00:39:05.086491+01:00"
close-reason: Added if_return_elif_fallthrough corpus fixture and snapshot
blocks:
  - pez-fix-subprocess-root-e28bd5dc
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for subprocess; deps: pez-fix-subprocess-root-e28bd5dc; verification: new regression fails before fix and passes after.
