---
title: Match statement guard detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T16:54:38.220780+02:00\""
closed-at: "2026-01-15T16:55:04.107903+02:00"
---

decompile.zig:3749 - Detect case pattern if condition: guards. After pattern extraction, scan for expr + POP_JUMP_IF_FALSE, decompile guard using stack sim, store in MatchCase.guard. Test: create match_guard.py for 3.10+.
