---
title: Expand snapshot coverage matrix
status: open
priority: 2
issue-type: task
created-at: "2026-02-07T09:49:04.673425+01:00"
blocks:
  - pez-drain-remaining-boat-615a5db9
---

Files: src/snapshot_tests.zig + src/test_boat_main_regressions_snapshot.zig + test/corpus_src/*; cause: coverage gaps in decorators/classes/control-flow/expr variants; fix: add targeted snapshots per category and py-version deltas; why: prevent structural regressions.
