---
title: Add telebot types regression
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.509523+01:00\""
closed-at: "2026-02-05T22:27:33.518505+01:00"
close-reason: completed
blocks:
  - pez-fix-telebot-types-ed45c52a
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: fix not locked by tests; fix: add minimal fixture and snapshot/assertions for telebot types; deps: pez-fix-telebot-types-ed45c52a; verification: new regression fails before fix and passes after.
