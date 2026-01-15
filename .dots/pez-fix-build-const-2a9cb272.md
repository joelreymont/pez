---
title: Fix BUILD_CONST_KEY_MAP tuple check
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:28:59.548833+02:00"
---

Files: src/stack.zig:3466
Issue: Dict shows as {**value, **('key',)} in build_const_key_map.3.8.pyc
Root cause: keys_val.expr.* == .tuple comparison wrong for tagged union
Fix: Use switch(keys_val.expr.*) { .tuple => |t| ... }
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/build_const_key_map.3.8.pyc shows {'key': value}
