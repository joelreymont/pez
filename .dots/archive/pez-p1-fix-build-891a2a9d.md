---
title: "P1: Fix BUILD_CONST_KEY_MAP tuple check"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:48:47.709533+02:00\""
closed-at: "2026-01-16T06:49:24.480225+02:00"
---

src/stack.zig:3466 - Replace broken tagged union comparison with proper switch. Currently outputs {**value, **('key',)} instead of {'key': value}. Spec: Phase 2
