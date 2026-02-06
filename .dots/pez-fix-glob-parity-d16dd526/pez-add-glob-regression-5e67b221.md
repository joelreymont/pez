---
title: Add glob regression snapshot
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:38:19.701428+01:00\""
closed-at: "2026-02-06T12:49:08.394292+01:00"
close-reason: implemented in 9f96c628
blocks:
  - pez-fix-glob-root-aa90fd12
---

Context: test/corpus_src + test/corpus + src/test_boat_main_regressions_snapshot.zig; cause: prevent parity regression; fix: add minimal fixture + pyc + snapshot test; deps: pez-fix-glob-root-aa90fd12; verification: zig build test includes new snapshot
