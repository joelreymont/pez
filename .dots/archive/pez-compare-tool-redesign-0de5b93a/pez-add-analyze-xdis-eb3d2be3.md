---
title: Add analyze_xdis tests
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-18T10:44:38.184128+02:00\""
closed-at: "2026-01-18T10:45:29.060424+02:00"
close-reason: completed
---

Refines dot: pez-compare-tool-unit-8258c73e. Files: tools/compare/tests/run.py (new). Root cause: no coverage for analyze_xdis. Fix: add a test that compiles a tiny module to .pyc and asserts analyze_xdis JSON keys and nonzero block/op counts. Verify: python3 tools/compare/tests/run.py
