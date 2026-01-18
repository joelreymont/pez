---
title: Review 2026-01-18 fixes
status: active
priority: 1
issue-type: task
created-at: "\"2026-01-18T06:54:07.865631+02:00\""
---

Full context: src/stack.zig/src/decompile.zig deep review (docs/code-review-2026-01-18.md); root cause: hot-path allocs, clone cost, merge churn, call arg duplication; fix: implement scratch buffers, reuse clone sim, consolidate call arg handling, merge reuse, comp builder sharing; why: performance/correctness parity with pycdc/uncompyle6.
