---
title: Fix for-body header reentry
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T15:52:52.341123+02:00\\\"\""
closed-at: "2026-01-17T15:53:22.315263+02:00"
close-reason: completed
---

Full context: src/decompile.zig:8270 in decompileForBody, block_idx can jump to header_block_id via inner while exit (e.g. concurrent.futures.process _chain_from_iterable_of_lists), causing recursive for emission + runaway indentation. Fix: stop body scan when block_idx == header_block_id (and/or skip processing when p.exit_block == header) to prevent reentering outer header.
