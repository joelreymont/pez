---
title: Refactor sim helpers
status: open
priority: 2
issue-type: task
created-at: "2026-01-17T22:29:55.705704+02:00"
---

Context: src/decompile.zig:1845-2025. Root cause: duplicate simulate* helpers w/ slight behavior differences and inconsistent error handling. Fix: unify into one helper with options (skip, stop_on_cond, stop_on_stmt) to reduce divergence.
