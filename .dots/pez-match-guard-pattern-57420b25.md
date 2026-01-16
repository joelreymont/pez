---
title: "Match guard: pattern extraction with OR support"
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T11:13:03.034023+02:00"
---

Update extractMatchPattern to take CasePattern with alts, handle OR patterns (create MatchOr AST), refactor extractSinglePattern for multi-block, use stack sim for seq/map/class, handle wildcard/capture. File: src/decompile.zig. Depends on: pez-match-guard-rewrite-87a8e17a. Ref: /tmp/match_guard_plan_final.md Phase 7
