---
title: Fix mismatch glob
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-05T20:11:24.816452+01:00\\\"\""
closed-at: "2026-02-06T09:32:11.431110+01:00"
close-reason: glob mismatch closed in commit 3436ab5f
blocks:
  - pez-fix-mismatch-ftplib-3c84df1c
---

Context: /tmp/pez-boatmain-suite17/pez_compare.json; cause: min_semantic_score ~0.2; fix: locate_mismatch + decompiler change + tests; deps: pez-fix-mismatch-ftplib-3c84df1c; verification: compare_driver exact + zig build test
