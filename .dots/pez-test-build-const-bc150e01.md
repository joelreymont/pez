---
title: Test BUILD_CONST_KEY_MAP output
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:35.005009+02:00"
---

File: refs/pycdc/tests/compiled/build_const_key_map.3.8.pyc
Run pez and verify output shows:
- Input: {'key': value}
- NOT: {**value, **('key',)}
Compare with pycdc output
Dependencies: pez-fix-tuple-check-6a913b7d
Verify: ./zig-out/bin/pez refs/pycdc/tests/compiled/build_const_key_map.3.8.pyc
