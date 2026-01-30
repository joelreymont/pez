---
title: stackflow-base
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T19:15:49.250931+01:00"
---

Full context: src/decompile.zig:2310,2456,6441; cause: scratch arenas used arena allocator as backing, causing growth + poor reset; fix: use base allocator and reuse arena in computeStackInRange; why: bounded memory + better perf.
