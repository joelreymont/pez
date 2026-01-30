---
title: [CRIT] listcomp-free
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.479878+01:00"
---

Full context: src/pycdc_tests.zig:94; cause: unknown invalid free when decompiling test_listComprehensions.2.7.pyc; fix: repro with debug allocator/trace, identify double-free, add regression test.
