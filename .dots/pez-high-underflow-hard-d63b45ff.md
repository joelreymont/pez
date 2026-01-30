---
title: [HIGH] underflow-hard
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.497168+01:00"
---

Full context: src/decompile.zig:18592-18595,3207-3217; cause: allow_underflow + pop orelse unknown masks stack underflow; fix: gate underflow only in pattern-matching, hard-fail otherwise; add diagnostics.
