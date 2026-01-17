---
title: [LOW] arraylist unmanaged
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T22:12:44.104586+02:00"
---

Full context: src/decompile.zig:55 (representative). Cause: std.ArrayList used across hot paths; Zig 0.15 expects ArrayListUnmanaged with allocator passed to methods; current pattern adds overhead and is inconsistent. Fix: convert all ArrayList to ArrayListUnmanaged and add prealloc for predictable sizes.
