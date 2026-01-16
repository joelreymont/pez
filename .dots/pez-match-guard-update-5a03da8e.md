---
title: "Match guard: update decompilation logic"
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T11:13:07.160675+02:00"
---

Update decompileMatchCase signature (CasePattern param), extract guard from guard_blocks (concat expressions), use body region blocks from CasePattern. File: src/decompile.zig. Depends on: pez-match-guard-pattern-57420b25. Ref: /tmp/match_guard_plan_final.md Phase 8
