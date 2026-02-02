---
title: boat_main exceptions
status: open
priority: 2
issue-type: task
created-at: "2026-02-02T22:15:10.038302+01:00"
---

Full context: src/decompile.zig:11750-19105 - cause: try/except/finally/with import edges mis-reconstructed; fix: validate handler boundaries + cleanup-only blocks and add snapshots; why: high semantic mismatch tail.
