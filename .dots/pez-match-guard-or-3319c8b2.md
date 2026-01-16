---
title: "Match guard: OR alternative detection"
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T11:12:45.810002+02:00"
---

Implement detectCaseAlternatives: walk via success edges collecting pattern blocks, follow fail edges to find next alt, detect OR by COPY at fail target. Add tests for single-alt and OR patterns. File: src/ctrl.zig. Depends on: pez-match-guard-update-f27727d8. Ref: /tmp/match_guard_plan_final.md Phase 3
