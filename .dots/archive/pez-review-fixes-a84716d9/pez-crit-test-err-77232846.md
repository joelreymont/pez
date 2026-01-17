---
title: [CRIT] Test error masking
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T09:03:34.456967+02:00\""
closed-at: "2026-01-17T09:28:01.216275+02:00"
close-reason: completed
---

File: src/property_tests.zig:156-208, 392-419. Root cause: catch return true/false and catch {} / unreachable in property tests. Fix: use explicit error union handling without catch-return patterns; treat errors as failures. Why: enforce error policy + reliable property tests.
