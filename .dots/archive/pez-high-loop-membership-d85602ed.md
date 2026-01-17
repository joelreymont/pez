---
title: [HIGH] loop membership cache
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T22:12:40.939895+02:00\""
closed-at: "2026-01-16T22:57:16.265651+02:00"
---

Full context: src/ctrl.zig:1744. Cause: findEnclosingLoops scans all blocks per query, causing O(n^2) behavior in dense CFGs. Fix: compute loop membership once (from DomTree loop_bodies), store per-block enclosing loop stack or bitset, and use it for break/continue detection.
