---
title: Compare_dir semantic ranking
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-18T10:35:28.965234+02:00\\\"\""
closed-at: "2026-01-18T10:43:53.093091+02:00"
close-reason: completed
---

Refines dot: pez-update-compare-dir-a909a1c8. File: tools/compare/compare_dir.py:80-140. Root cause: worst list only uses seq ratio. Fix: add worst_semantic list sorted by semantic score + tier; keep legacy fields for regressions.
