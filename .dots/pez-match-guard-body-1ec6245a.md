---
title: "Match guard: body region computation"
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T11:12:54.280787+02:00"
---

Implement computeReachable (BFS from start), computeCaseBodyRegion (reachable from body_start but not case_fail_target, using dominance). Add tests for linear and branching bodies. File: src/ctrl.zig. Depends on: pez-match-guard-guard-478fc7a7. Ref: /tmp/match_guard_plan_final.md Phase 5
