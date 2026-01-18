---
title: Cache block patterns
status: open
priority: 1
issue-type: task
created-at: "2026-01-17T22:29:52.553391+02:00"
---

Context: src/ctrl.zig:369-433. Root cause: detectPattern recomputes per call; decompile + debug dumps re-scan blocks and can allocate (match/try patterns). Fix: add per-block cache with invalidation when processed changes; expose batch detect pass.
