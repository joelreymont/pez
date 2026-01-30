---
title: [MED] postdom-fast
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.510647+01:00"
---

Full context: src/cfg.zig:319-386; cause: fixed-point bitset + nested ipdom scan is O(n^3); fix: faster postdom (LT) or reduce set ops; add perf bench.
