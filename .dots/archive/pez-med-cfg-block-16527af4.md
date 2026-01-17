---
title: [MED] cfg-block-lookup
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T21:32:55.863255+02:00\""
closed-at: "2026-01-16T22:04:44.286136+02:00"
close-reason: completed
---

Full context: src/cfg.zig:126-134 blockContaining is linear scan; used in decompile (src/decompile.zig:3438) and CFG exception wiring. Fix: add offset->block index map built once during CFG build for O(1) lookups.
