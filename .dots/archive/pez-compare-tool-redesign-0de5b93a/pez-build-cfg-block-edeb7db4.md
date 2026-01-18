---
title: Build CFG + block invariants
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:32:34.951663+02:00\\\"\""
closed-at: "2026-01-18T10:42:33.156230+02:00"
close-reason: completed
---

File: tools/compare/compare.py:120-220. Root cause: no structural comparison. Fix: build basic blocks, edges, loop detection; compute per-block invariants (op-class hash, const/name multisets, call arity).
