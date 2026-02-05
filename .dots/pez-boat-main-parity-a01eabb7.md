---
title: Boat_main parity
status: active
priority: 1
issue-type: task
created-at: "\"2026-02-05T09:47:22.814382+01:00\""
---

Full context: boat_main decompile 329/329 OK; bytecode compare: exact=162 close=45 mismatch=122 error=0 (see /tmp/pez-boatmain-compare4.json). Remaining known suite failures: test_listComprehensions.2.7.pyc (Invalid free memory corruption), test_loops2.2.2.pyc (hang). Cause: remaining mismatches + tooling gaps. Fix: iterate mismatches from /tmp/pez-boatmain-compare4.json, for each use tools/compare/compare_driver.py + trace/dump skills to locate first divergence, fix decompiler root-cause (arena-backed), add minimal corpus + snapshot regression, zig build test + zig build, jj commit per fix. Also: integrate always-on decompyle3 (python-decompile3) parity run in tools/compare; ensure invalid pyc hard-fails in all tools with diagnostic + nonzero.
