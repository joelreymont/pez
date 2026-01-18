---
title: Reuse clone sim
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T06:54:27.775956+02:00\\\"\""
closed-at: "2026-01-18T07:16:59.466855+02:00"
close-reason: done
---

Full context: src/decompile.zig:491-535 cloneStackValues* allocates SimContext per call; root cause: fresh sim+heap per branch; fix: reuse per-decompiler clone SimContext or add clone scratch in Decompiler; why: reduce O(B*D) clone cost in CFG merges.
