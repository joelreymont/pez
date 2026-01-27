---
title: fix-listcomp-27
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T16:04:25.161134+01:00"
---

Full context: src/pycdc_tests.zig:89-94; cause: decompile of test_listComprehensions.2.7.pyc triggers memory corruption (invalid free); fix: reproduce under sanitizer/trace, identify double-free or ownership bug in comp/set/list handling, add regression test.
