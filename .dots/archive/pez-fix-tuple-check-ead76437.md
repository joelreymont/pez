---
title: Fix tuple check in BUILD_CONST_KEY_MAP handler
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-15T18:10:41.413761+02:00\""
closed-at: "2026-01-16T10:17:14.250949+02:00"
blocks:
  - pez-fix-build-const-6795adbe
---

src/stack.zig:3466 - Change:
  if (keys_val == .expr and keys_val.expr.* == .tuple)
To:
  if (keys_val == .expr) switch (keys_val.expr.*) { .tuple => ... }
Use proper Zig tagged union matching.
