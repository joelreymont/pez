---
title: Cache cond reachability
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T22:29:47.488305+02:00\\\"\""
closed-at: "2026-01-17T22:35:11.659968+02:00"
close-reason: completed
---

Context: src/decompile.zig:2046-2075. Root cause: condReach allocates DynamicBitSet + ArrayList each call -> O(N^2) allocs in bool/loop analysis. Fix: store reusable bitset+stack in Decompiler or precompute reachability per block.
