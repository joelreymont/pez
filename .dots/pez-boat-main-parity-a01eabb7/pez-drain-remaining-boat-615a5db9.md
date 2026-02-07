---
title: Drain remaining boat_main mismatches
status: open
priority: 1
issue-type: task
created-at: "2026-02-07T09:49:04.660711+01:00"
blocks:
  - pez-record-curr-boat-ccb838bb
---

Files: /tmp/pez-boatmain-suite-20260207/pez_compare.json + src/decompile.zig + src/stack.zig; cause: 48 mismatch files remain; fix: root-cause each mismatch with compare_driver/locate_mismatch and add regression snapshots; why: hit mismatch=0 ship gate.
