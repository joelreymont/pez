---
title: Fix class body return locals
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:30.600322+02:00"
---

Suppress return locals() at end of class bodies. Fix test_class.2.5.pyc, test_class_method_py3.3.7.pyc. Files: src/class.zig or src/decompile.zig. Dependencies: none. Verify: mentioned test files decompile without spurious return.
