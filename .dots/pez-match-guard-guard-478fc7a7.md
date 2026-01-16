---
title: "Match guard: guard region detection"
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T11:12:50.261474+02:00"
---

Implement failPathReaches (BFS along fail edges), detectGuardRegion (walk from pattern success, collect blocks with no match context whose fail path reaches case_fail). Add tests. File: src/ctrl.zig. Depends on: pez-match-guard-or-3319c8b2. Ref: /tmp/match_guard_plan_final.md Phase 4
