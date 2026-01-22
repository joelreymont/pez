---
title: stack cache
status: open
priority: 2
issue-type: task
created-at: "2026-01-24T12:38:43.257965+02:00"
---

Full context: src/decompile.zig:1900 initStackFlow; cause: repeated block simulation and no cached entry/exit states; fix: cache entry/exit stack states and reuse across expression recovery; why: correctness (stable values) + performance.
