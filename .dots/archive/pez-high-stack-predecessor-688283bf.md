---
title: [HIGH] stack-predecessor
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T21:32:45.134019+02:00\""
closed-at: "2026-01-16T21:58:23.266066+02:00"
close-reason: completed
---

Full context: src/decompile.zig:2641-2666 uses fixed 16-depth linear predecessor simulation and ignores merges; can build wrong stack and mis-decompile. Fix: replace with dataflow-based stack-state propagation over CFG joins, no arbitrary depth cap.
