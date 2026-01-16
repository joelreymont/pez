---
title: Fix BUILD_CONST_KEY_MAP tuple check
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:56:51.042449+02:00\""
closed-at: "2026-01-16T06:57:08.735451+02:00"
---

src/stack.zig:3466 - Replace broken .expr.* == .tuple check with proper switch, causes {'key': value} to output as {**value, **('key',)}
