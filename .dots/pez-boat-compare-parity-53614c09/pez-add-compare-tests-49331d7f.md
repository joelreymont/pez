---
title: Add compare tests
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T17:39:46.119151+02:00"
---

Full context: tools/compare/*.py; add unit tests for compare scoring and analyze_xdis normalization; create minimal .pyc fixtures in /tmp or test/corpus; ensure compare.py returns exact for identical roundtrip and flags mismatches; run via python3 -m pytest or custom runner.
