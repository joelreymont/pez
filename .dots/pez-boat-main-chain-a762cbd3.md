---
title: boat_main chain compare
status: open
priority: 2
issue-type: task
created-at: "2026-02-02T22:51:53.587386+01:00"
---

Full context: src/sc_pass.zig/src/decompile.zig; chain compare over slice ranges emits separate compares; cause missing stack dup/rot/compare-chain handling for range checks; fix: reconstruct chained compare for slice bounds and preserve bytecode; why: boat_main parity.
