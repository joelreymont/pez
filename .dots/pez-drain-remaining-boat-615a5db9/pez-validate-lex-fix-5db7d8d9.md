---
title: Validate lex fix and update suite
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-07T09:49:16.155599+01:00\""
closed-at: "2026-02-07T10:05:22.590270+01:00"
close-reason: validated via suite /tmp/pez-boatmain-suite-20260207-b.json (exact+1, mismatch unchanged)
blocks:
  - pez-add-lex-regression-af236d63
---

Files: /tmp suite artifacts + PLAN.md; cause: fix must prove parity movement; fix: run zig build test + compare_driver + compare_suite and record counts; why: measurable closure.
