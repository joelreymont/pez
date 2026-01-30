---
title: [HIGH] ternary-pend
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.502402+01:00"
---

Full context: src/decompile.zig:368,18558; cause: single pending_ternary_expr slot can be overwritten across blocks; fix: key pending ternaries per-block or per-merge; add test.
