---
title: Fix interned string deduplication
status: open
priority: 2
issue-type: task
created-at: "2026-01-07T17:37:16.733574+02:00"
---

File: src/pyc.zig - Current interns list may have duplicates. Use StringHashMap for O(1) lookup and proper deduplication.
