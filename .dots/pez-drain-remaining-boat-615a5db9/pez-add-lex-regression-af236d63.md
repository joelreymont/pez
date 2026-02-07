---
title: Add lex regression fixture+snapshot
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-07T09:49:16.151300+01:00\""
closed-at: "2026-02-07T09:57:06.819976+01:00"
close-reason: already present in tree (fixture + snapshot in src/test_boat_main_regressions_snapshot.zig)
blocks:
  - pez-patch-lex-divergence-64271ce3
---

Files: test/corpus_src/listcomp_ifexp.py + test/corpus/listcomp_ifexp.3.9.pyc + src/test_boat_main_regressions_snapshot.zig; cause: no direct regression lock for this pattern; fix: add corpus fixture and ohsnap snapshot; why: prevent recurrence.
