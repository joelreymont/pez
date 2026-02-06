---
title: Add ftplib regression snapshot
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:50:32.662775+01:00\""
closed-at: "2026-02-06T12:57:06.508160+01:00"
close-reason: implemented in 347078de
blocks:
  - pez-fix-ftplib-parse257-96e1ecc7
---

Context: test/corpus_src, test/corpus, src/test_boat_main_regressions_snapshot.zig; cause: protect parse257 parity; fix: minimal fixture + compiled pyc + snapshot; deps: pez-fix-ftplib-parse257-96e1ecc7; verification: zig build test passes with new snapshot
