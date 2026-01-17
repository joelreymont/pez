---
title: [MED] try-pattern-cost
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T21:33:00.357223+02:00\""
closed-at: "2026-01-16T22:04:48.412606+02:00"
close-reason: completed
---

Full context: src/ctrl.zig:230-289 calls detectTryPattern per block with exception edge; detectTryPattern allocates and scans handler targets each call (src/ctrl.zig:836-908), leading to O(n^2) on large CFGs. Fix: memoize try patterns per block or precompute handler reachability.
