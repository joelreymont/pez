---
title: [MED] Version tests
status: closed
priority: 3
issue-type: task
created-at: "\"2026-01-17T09:03:47.580970+02:00\""
closed-at: "2026-01-17T09:28:13.116835+02:00"
close-reason: completed
---

File: src/pycdc_tests.zig:31-35, src/test_harness.zig:421-422. Root cause: expectEqual on struct Version. Fix: compare fields or use ohsnap. Why: comply with testing rules.
