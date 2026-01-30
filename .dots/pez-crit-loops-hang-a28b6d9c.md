---
title: [CRIT] loops-hang
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.483311+01:00"
---

Full context: src/pycdc_tests.zig:86; cause: unknown hang when decompiling test_loops2.2.2.pyc; fix: repro with timeout+trace, isolate loop, add regression test.
