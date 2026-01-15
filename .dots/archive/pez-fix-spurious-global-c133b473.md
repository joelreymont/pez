---
title: Fix spurious global declaration
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-15T18:06:58.680905+02:00\""
closed-at: "2026-01-15T18:29:33.195699+02:00"
---

src/decompile.zig:5293 generates 'global' for both STORE_GLOBAL and LOAD_GLOBAL.
Bug: 'global print' appears in output when print is only read, not assigned.
Fix: Change condition to only check STORE_GLOBAL (remove LOAD_GLOBAL).
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/test_class_method_py3.3.7.pyc should not have 'global print'
