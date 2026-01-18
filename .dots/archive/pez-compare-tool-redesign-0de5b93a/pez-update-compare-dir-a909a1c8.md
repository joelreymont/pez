---
title: Update compare_dir ranking
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-18T10:32:49.909475+02:00\\\"\""
closed-at: "2026-01-18T10:44:01.270948+02:00"
close-reason: completed
---

File: tools/compare/compare_dir.py:60-140. Root cause: worst list uses seq ratio only. Fix: rank by semantic score and include worst-by-tier + legacy ratios for regressions.
