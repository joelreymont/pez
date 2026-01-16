---
title: Test exception handler fix
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:05:09.946336+02:00"
---

After fixing handler stack init, run: ./zig-out/bin/pez refs/pycdc/tests/compiled/async_for.3.7.pyc and try_except_finally.2.6.pyc. Should parse without StackUnderflow. Add unit test
