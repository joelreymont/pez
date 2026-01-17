---
title: Fix compare compile timeout
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T15:58:54.187194+02:00\\\"\""
closed-at: "2026-01-17T16:12:37.940464+02:00"
close-reason: completed
---

Full context: tools/compare/compare.py compile_source uses 30s timeout; pycparser/ply/yacc.py compile timed out. Fix by allowing per-file override or increasing timeout and surfacing long-compile info.
