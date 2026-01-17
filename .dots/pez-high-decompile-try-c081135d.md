---
title: [HIGH] decompile try perf
status: open
priority: 2
issue-type: task
created-at: "2026-01-17T06:39:32.805975+02:00"
---

Full context: /tmp/pez.sample.release.txt shows heavy time/allocs in decompileTry and DynamicBitSet resize, with physical footprint ~10GB. Fix: reduce allocations in decompileTry (prealloc handler_blocks, reuse bitsets/queues), avoid repeated scans of handler ranges, and cache handler end search.
