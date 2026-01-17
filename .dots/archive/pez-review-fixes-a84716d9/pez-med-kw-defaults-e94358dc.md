---
title: [MED] Kw defaults test
status: closed
priority: 3
issue-type: task
created-at: "\"2026-01-17T09:03:52.195849+02:00\""
closed-at: "2026-01-17T09:28:16.978700+02:00"
close-reason: completed
---

File: test/corpus_src/kw_defaults.py, test/corpus/kw_defaults.3.14.pyc, src/test_kw_defaults_snapshot.zig. Root cause: kw-only defaults mapping lacks regression coverage. Fix: add corpus + snapshot, compile pyc. Why: lock kw defaults behavior for parity.
