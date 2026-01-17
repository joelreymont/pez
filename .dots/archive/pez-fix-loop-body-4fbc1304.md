---
title: Fix loop body header reentry
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T16:00:43.754254+02:00\\\"\""
closed-at: "2026-01-17T16:07:29.010610+02:00"
close-reason: completed
---

Full context: src/decompile.zig:8960 in decompileLoopBody; next_id/merge_id can jump back to loop_header (non-loop_back edge), causing re-entry and massive duplication (pycparser/ply/yacc.py). Add guard to stop when block_idx == loop_header (except start) and when next/merge targets header.
