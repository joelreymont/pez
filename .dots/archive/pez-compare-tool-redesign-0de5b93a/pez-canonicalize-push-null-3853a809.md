---
title: Canonicalize PUSH_NULL+LOAD_GLOBAL
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:34:46.466812+02:00\\\"\""
closed-at: "2026-01-18T10:41:56.048507+02:00"
close-reason: completed
---

File: tools/compare/compare.py:90-140. Root cause: 3.11+ call prep noise. Fix: fold PUSH_NULL+LOAD_GLOBAL into single semantic op in normalization.
