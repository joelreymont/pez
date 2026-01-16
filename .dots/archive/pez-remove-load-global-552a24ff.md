---
title: Remove LOAD_GLOBAL from global declaration detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T08:05:08.416095+02:00\""
closed-at: "2026-01-16T08:07:17.347748+02:00"
---

src/decompile.zig:5293 - Only emit 'global' for STORE_GLOBAL, not LOAD_GLOBAL. Reading global doesn't require declaration. Test: test_class_method_py3.3.7.pyc should not show 'global print'
