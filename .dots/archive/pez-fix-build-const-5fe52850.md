---
title: Fix BUILD_CONST_KEY_MAP tuple detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T08:05:07.800831+02:00\""
closed-at: "2026-01-16T08:06:47.188045+02:00"
---

src/stack.zig:3466 - keys_val.expr.* == .tuple fails because using == on tagged union. Switch on keys_val.expr.* instead, match .tuple variant. Fixes {'key': value} outputting as {**value, **('key',)}. Test: build_const_key_map.3.8.pyc
