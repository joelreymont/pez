---
title: pattern cache
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T06:25:31.924690+02:00"
---

Context: src/ctrl.zig:369-433,1901-1908. Root cause: detectPattern recomputes per call, re-allocates patterns. Fix: add per-block cache struct with ownership; store pattern kind + data; add invalidation on markProcessed/changes; update debug_dump to use cached values and deinit correctly. Why: perf + determinism.
