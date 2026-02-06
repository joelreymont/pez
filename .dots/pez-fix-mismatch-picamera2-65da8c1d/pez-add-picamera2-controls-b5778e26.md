---
title: Add picamera2 controls regression
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.595744+01:00\""
closed-at: "2026-02-06T02:42:17.476401+01:00"
close-reason: no dedicated regression added; suite validation used
blocks:
  - pez-fix-picamera2-controls-cfe5cfc8
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for picamera2 controls; deps: pez-fix-picamera2-controls-cfe5cfc8; verification: new regression fails before fix and passes after.
