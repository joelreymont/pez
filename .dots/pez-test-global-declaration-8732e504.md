---
title: Test global declaration fix
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:05:10.252237+02:00"
---

After removing LOAD_GLOBAL from global detection, run: ./zig-out/bin/pez refs/pycdc/tests/compiled/test_class_method_py3.3.7.pyc. Verify no 'global print' in output
