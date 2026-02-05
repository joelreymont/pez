---
title: Add aioice regression fixture
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:24:34.045617+01:00\""
closed-at: "2026-02-05T22:09:30.628418+01:00"
close-reason: completed
blocks:
  - pez-fix-handler-range-a8dcd17a
---

Context: test/corpus_src:1, test/corpus:1, src/snapshot_tests.zig:1; cause: no locked regression for nested async try/except/finally cleanup; fix: add minimal source/pyc fixture and snapshot coverage for resolved pattern; deps: pez-fix-handler-range-a8dcd17a; verification: new test fails pre-fix and passes post-fix.
