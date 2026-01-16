---
title: Add test for BUILD_CONST_KEY_MAP 3.8
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-15T18:10:41.410147+02:00\""
closed-at: "2026-01-16T10:18:07.790446+02:00"
blocks:
  - pez-fix-build-const-6795adbe
---

Add snapshot test for refs/pycdc/tests/compiled/build_const_key_map.3.8.pyc.
Expected output should show dict literal {'Accept': 'application/json', ...}
Not dict unpacking {**value, **('key',)}
File: src/snapshot_tests.zig or new test file
