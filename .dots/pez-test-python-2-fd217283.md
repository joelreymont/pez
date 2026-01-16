---
title: Test Python 2.x class body fix
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:05:10.555661+02:00"
---

After suppressing 'return locals()', run: ./zig-out/bin/pez refs/pycdc/tests/compiled/test_class.2.5.pyc. Verify class body doesn't end with 'return locals()'
