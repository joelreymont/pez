---
title: "Fix spurious 'global' declarations"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:46:45.699775+02:00"
---

src/decompile.zig:5293 - Remove LOAD_GLOBAL from condition, only STORE_GLOBAL should trigger global declaration. Test: test_class_method_py3.3.7.pyc should not show 'global print'.
