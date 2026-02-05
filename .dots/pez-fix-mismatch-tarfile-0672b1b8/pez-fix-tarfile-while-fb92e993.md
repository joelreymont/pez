---
title: Fix tarfile while-head guard parity
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-05T23:03:14.567385+01:00\\\"\""
closed-at: "2026-02-05T23:03:26.071109+01:00"
close-reason: "Implemented and committed: exit-guard preservation + while-head return rewrite pass; tests and tarfile compare improved"
---

Context: /Users/joel/Work/pez/src/decompile.zig:205,216,12851; cause: loop-exit guard gating dropped terminal head-return tails and kept non-canonical while-true heads; fix: always process contentful exit blocks and run rewriteWhileHeadReturnDeep in function/module pipelines; deps: repro+locate tarfile done; verification: zig build test + compare_driver tarfile exact_units/min_semantic improvements
