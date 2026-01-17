---
title: Review fixes
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T09:03:09.035714+02:00\""
closed-at: "2026-01-17T09:28:25.339533+02:00"
close-reason: completed
---

Context: src/decompile.zig, src/stack.zig, src/ctrl.zig, src/property_tests.zig, src/pycdc_tests.zig, src/test_harness.zig. Root cause: error masking + perf regressions + equality gaps. Fix: eliminate catch-return patterns, add expr equality, finalize flow-mode stack analysis, update tests. Why: correctness/perf and parity.
