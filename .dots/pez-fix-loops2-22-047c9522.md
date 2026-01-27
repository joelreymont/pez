---
title: fix-loops2-22
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T16:04:29.181898+01:00"
---

Full context: src/pycdc_tests.zig:81-87; cause: decompile of test_loops2.2.2.pyc hangs; fix: capture loop trace/decision trace, find non-terminating traversal or loop-guard rewrite, add regression test.
