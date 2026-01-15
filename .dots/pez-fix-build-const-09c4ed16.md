---
title: Fix BUILD_CONST_KEY_MAP tuple check
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:50:11.135921+02:00"
---

Files: src/stack.zig:3466
Current: keys_val.expr.* == .tuple fails on tuple constants.
Fix: Replace equality check with switch statement on keys_val.expr.*.
Switch .tuple arm extracts keys, else arm sets nulls.
Test: ./zig-out/bin/pez tests/compiled/build_const_key_map.3.8.pyc should show {'key': value} not unpacking.
