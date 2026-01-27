---
title: Capture failures
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T12:12:28.343897+01:00"
---

Context: src/test_root.zig:1; cause: unknown baseline failures/hangs after recent fixes; fix: run zig build test + targeted pyc repros (test_listComprehensions.2.7.pyc, test_loops2.2.2.pyc) and record failing snapshots; deps: none; verification: failure list in dot note.
