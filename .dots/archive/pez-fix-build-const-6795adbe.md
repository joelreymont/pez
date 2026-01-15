---
title: Fix BUILD_CONST_KEY_MAP tuple check
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-15T18:06:47.038840+02:00\\\"\""
closed-at: "2026-01-15T18:19:00.934419+02:00"
---

src/stack.zig:3466 - keys_val.expr.* == .tuple check fails for tagged union.
Bug: Dict displayed as {**value, **('key',)} instead of {'key': value}.
Fix: Use switch on keys_val.expr.* to match .tuple variant properly.
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/build_const_key_map.3.8.pyc should show dict literal
