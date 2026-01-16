---
title: "Match guard: rewrite detectMatchPattern"
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T11:12:58.401047+02:00"
---

Rewrite detectMatchPattern: find case entry blocks, call detectCaseAlternatives per case, call detectGuardRegion, find body_block, call computeCaseBodyRegion. Update isMatchSubjectBlock. File: src/ctrl.zig. Depends on: pez-match-guard-body-1ec6245a. Ref: /tmp/match_guard_plan_final.md Phase 6
