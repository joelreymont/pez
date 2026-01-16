---
title: "Phase 2: Add test for BUILD_CONST_KEY_MAP output"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:23:48.970412+02:00\""
closed-at: "2026-01-16T10:18:55.869247+02:00"
---

Verify build_const_key_map.3.8.pyc decompiles to '{"key": value}' not '{**value, **("key",)}'. Add ohsnap snapshot test.
