---
title: Fix if merge range
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T08:02:42.109542+02:00\\\"\""
closed-at: "2026-01-18T08:05:41.651804+02:00"
close-reason: completed
---

Full context: src/decompile.zig:3810-3905 decompileIfWithSkip uses merge_block null -> else/then branch ranges run to end; inspect.pyc _signature_from_callable decompiles with massive nested else after returns (compare min_seq_ratio 0.015). Cause: missing branch end when merge_block null. Fix: compute branch end from reachable blocks (ignore back edges) and use when merge_block absent.
