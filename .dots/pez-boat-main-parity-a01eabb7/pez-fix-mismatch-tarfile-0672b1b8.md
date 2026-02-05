---
title: Fix mismatch tarfile
status: open
priority: 1
issue-type: task
created-at: "2026-02-05T20:10:59.820657+01:00"
blocks:
  - pez-fix-mismatch-telebot-a5980562
---

Context: /tmp/pez-boatmain-suite17/pez_compare.json; cause: min_semantic_score ~0.2; fix: locate_mismatch + decompiler change + tests; deps: pez-fix-mismatch-telebot-a5980562; verification: compare_driver exact + zig build test
