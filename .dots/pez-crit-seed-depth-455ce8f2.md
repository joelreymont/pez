---
title: [CRIT] seed-depth
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.486066+01:00"
---

Full context: src/decompile.zig:6222,18565; cause: fixed [16] predecessor chain truncates stack seeding; fix: replace with dynamic list or error on overflow; add test for deep pred chain.
