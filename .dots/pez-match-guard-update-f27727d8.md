---
title: "Match guard: update data structures"
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T11:12:41.651587+02:00"
---

Add CaseAlt struct (entry_block, pattern_blocks, fail_target, success_target), update CasePattern (alts, guard_blocks array), update deinit methods. File: src/ctrl.zig. Depends on: pez-match-guard-edge-20400c6e. Ref: /tmp/match_guard_plan_final.md Phase 2
