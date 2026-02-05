---
title: Add picamera2 controls regression
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.595744+01:00"
blocks:
  - pez-fix-picamera2-controls-cfe5cfc8
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for picamera2 controls; deps: pez-fix-picamera2-controls-cfe5cfc8; verification: new regression fails before fix and passes after.
