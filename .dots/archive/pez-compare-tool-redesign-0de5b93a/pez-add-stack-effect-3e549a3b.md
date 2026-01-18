---
title: Add stack effect + meta invariants
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:32:40.391625+02:00\\\"\""
closed-at: "2026-01-18T10:43:01.997164+02:00"
close-reason: completed
---

File: tools/compare/compare.py:220-340. Root cause: no stack semantics checks. Fix: compute stack delta/max per block (oppop/oppush + overrides) and meta invariants (arg counts, flags, freevars/cellvars, stacksize).
