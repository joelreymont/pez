---
title: Improve analyze_xdis invariants
status: active
priority: 1
issue-type: task
created-at: "\"2026-01-18T17:39:05.553973+02:00\""
---

Full context: tools/compare/analyze_xdis.py:233-457; block/edge signatures overfit offsets; redesign signatures to be stable across decompile/compile (normalize jump targets, collapse NOP/CACHE, include stack delta/const/name bins) and add unit tests.
