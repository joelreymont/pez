---
title: Skip unreachable blocks
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T21:59:25.563585+02:00\""
closed-at: "2026-01-17T21:59:29.862498+02:00"
close-reason: fixed
---

Full context: src/decompile.zig decompiled dead blocks (no predecessors), causing extra returns in functions like stringprep.map_table_b2; fix by skipping unreachable blocks in decompile loops.
