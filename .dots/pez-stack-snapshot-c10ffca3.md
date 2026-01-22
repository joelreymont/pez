---
title: stack snapshot
status: open
priority: 2
issue-type: task
created-at: "2026-01-22T10:11:35.177150+02:00"
---

Full context: src/decompile.zig:210-245 pending_* side channels (pending_ternary_expr/pending_store_expr/pending_vals) leak stack state across blocks. Cause: implicit stack carry makes flow hard to reason about. Fix: replace pending_* with explicit stack snapshot object threaded through decompile/cond sim. Why: correctness + debuggability.
