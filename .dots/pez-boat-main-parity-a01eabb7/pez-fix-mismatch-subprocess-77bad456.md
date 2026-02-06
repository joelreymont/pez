---
title: Fix mismatch subprocess
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-05T20:11:04.703700+01:00\""
closed-at: "2026-02-06T02:40:41.388433+01:00"
close-reason: no mismatch in suite25; now close
blocks:
  - pez-fix-mismatch-tarfile-0672b1b8
---

Context: /tmp/pez-boatmain-suite17/pez_compare.json; cause: min_semantic_score ~0.2; fix: locate_mismatch + decompiler change + tests; deps: pez-fix-mismatch-tarfile-0672b1b8; verification: compare_driver exact + zig build test
