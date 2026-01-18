---
title: Fix if chain end
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T08:13:36.789246+02:00\\\"\""
closed-at: "2026-01-18T08:15:39.986339+02:00"
close-reason: completed
---

Full context: src/decompile.zig:3025 findIfChainEnd uses max_block+1 when merge_block null; outer if skips only else_id+1, leaving inner blocks processed twice (see test/corpus/if_prelude_then_if.3.9.pyc extra returns). Fix: compute end using branchEnd for then/else and elif recursion.
