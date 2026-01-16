---
title: Test BUILD_CONST_KEY_MAP fix
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:05:09.638886+02:00"
---

After fixing src/stack.zig:3466, run: ./zig-out/bin/pez refs/pycdc/tests/compiled/build_const_key_map.3.8.pyc. Verify output shows {'key': value} not {**value, **('key',)}. Add ohsnap snapshot test
