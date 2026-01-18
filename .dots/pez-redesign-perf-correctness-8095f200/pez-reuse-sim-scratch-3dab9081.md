---
title: Reuse sim scratch
status: open
priority: 1
issue-type: task
created-at: "2026-01-17T22:29:42.471041+02:00"
---

Context: src/decompile.zig:1853,1880,1908,1938,1999. Root cause: per-call SimContext init on arena -> unbounded arena growth and alloc churn. Fix: add reusable scratch allocator or SimContext pool/reset; avoid arena for short-lived sims.
