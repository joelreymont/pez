---
title: Normalize jump features
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T17:39:38.147984+02:00"
---

Full context: tools/compare/analyze_xdis.py:249-426; current block/edge sigs embed jump target positions; add normalization (edge type counts + jump distance bins) to reduce false mismatches; update compare scoring in tools/compare/compare.py:196-241.
