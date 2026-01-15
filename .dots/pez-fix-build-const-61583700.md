---
title: Fix BUILD_CONST_KEY_MAP tuple pattern check
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:59:13.546876+02:00"
---

Files: src/stack.zig:3466
Change: Replace direct tagged union comparison with switch
- Current: keys_val.expr.* == .tuple (fails)
- Fix: Use switch on keys_val.expr.* with .tuple => |t| capture
- Extract tuple elements into keys array
Verify: Decompile build_const_key_map.3.8.pyc, should output {'key': value} not {**value, **('key',)}
