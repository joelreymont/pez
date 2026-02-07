---
title: Run final parity gate
status: open
priority: 1
issue-type: task
created-at: "2026-02-07T09:49:04.685630+01:00"
blocks:
  - pez-wire-ver-matrix-5a7c1df8
---

Files: PLAN.md + /tmp suite artifacts; cause: release gate not executed on latest code; fix: run zig build test + compare_suite + parity harness and record mismatch=0/error=0 criteria; why: ship readiness.
