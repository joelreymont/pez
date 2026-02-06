---
title: Add tarfile regression snapshot
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T13:06:18.989050+01:00\""
closed-at: "2026-02-06T13:23:22.381710+01:00"
close-reason: implemented
blocks:
  - pez-fix-tarfile-add-d29de1e9
---

Context: test/corpus_src + test/corpus + src/test_boat_main_regressions_snapshot.zig; cause: protect TarFile.add fallthrough parity; fix: minimal fixture and snapshot; deps: pez-fix-tarfile-add-d29de1e9; verification: zig build test passes
