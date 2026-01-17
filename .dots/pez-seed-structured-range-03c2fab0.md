---
title: Seed structured range
status: open
priority: 1
issue-type: task
created-at: "2026-01-17T12:52:45.390619+02:00"
---

Full context: src/decompile.zig:6968. Cause: decompileStructuredRangeWithStack reused init_stack for every block, ignoring stack_in for later blocks; caused underflows in processBlockWithSim (e.g., contextlib ROT_FOUR). Fix: use init_stack only for start block, otherwise seed from stack_in.
