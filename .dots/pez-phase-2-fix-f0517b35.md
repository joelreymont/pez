---
title: "Phase 2: Fix BUILD_CONST_KEY_MAP tuple check"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:23:48.666397+02:00"
---

src/stack.zig:3466 - Replace 'keys_val.expr.* == .tuple' with switch on expr variant. Currently outputs '{**value, **("key",)}' instead of '{"key": value}' for build_const_key_map.3.8.pyc
