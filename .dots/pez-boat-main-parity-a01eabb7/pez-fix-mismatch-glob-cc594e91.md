---
title: Fix mismatch glob
status: open
priority: 1
issue-type: task
created-at: "2026-02-05T20:11:24.816452+01:00"
blocks:
  - pez-fix-mismatch-ftplib-3c84df1c
---

Context: /tmp/pez-boatmain-suite17/pez_compare.json; cause: min_semantic_score ~0.2; fix: locate_mismatch + decompiler change + tests; deps: pez-fix-mismatch-ftplib-3c84df1c; verification: compare_driver exact + zig build test
