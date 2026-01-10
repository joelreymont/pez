---
title: Implement snapshot test harness
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-10T06:37:24.954531+02:00\""
closed-at: "2026-01-10T06:50:41.911203+02:00"
---

File: src/test_harness.zig (NEW). Requirements from docs/testing-plan.md: Feed .pyc fixtures, compare output to expected .py. Implementation: 1) Create test harness that loads .pyc, 2) Decompiles to string, 3) Compares against .py.expected golden file, 4) Reports diff on mismatch. Structure: iterate refs/pycdc/tests/compiled/*.pyc, load .py source as golden. Priority: P2-MEDIUM. Enables systematic regression testing.
