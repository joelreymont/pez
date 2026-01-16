---
title: "Phase 4: Fix spurious 'global' declarations"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:23:49.886782+02:00\""
closed-at: "2026-01-16T10:18:55.879858+02:00"
---

src/decompile.zig:5293 - Remove LOAD_GLOBAL from global detection (only STORE_GLOBAL should generate 'global' declaration). Fixes 'global print' in test_class_method_py3.3.7.pyc
