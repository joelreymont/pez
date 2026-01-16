---
title: "Match guard: edge cases and finalization"
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T11:13:17.335079+02:00"
---

Handle multi-block guards (and/or conditions), wildcard-only case (no MATCH_* opcodes), class patterns with LOAD_ATTR, version-specific opcodes (3.10/3.11/3.12/3.14). Verify all tests pass. Depends on: pez-match-guard-comprehensive-fd2dee5e. Ref: /tmp/match_guard_plan_final.md Phase 10
