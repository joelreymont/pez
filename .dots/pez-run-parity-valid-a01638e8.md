---
title: Run parity validation suite
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:30.909756+02:00"
---

Run roundtrip tests on 1000+ corpus files. Compare with pycdc (2.3-3.11) and uncompyle6 (2.7-3.8) outputs (AST-based, normalized). Measure parity percentage. Generate report of failures. Files: test/parity_report.zig or script. Dependencies: all previous dots. Verify: parity report shows 100% for implemented features.
