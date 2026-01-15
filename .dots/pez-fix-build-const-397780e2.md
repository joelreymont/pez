---
title: Fix BUILD_CONST_KEY_MAP tuple check
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:46:45.090041+02:00"
---

src/stack.zig:3466 - Replace broken equality check 'keys_val.expr.* == .tuple' with proper switch statement to extract tuple elements. Current: dict displays as unpacking. Fix: use switch on keys_val.expr.* with .tuple => |t| capture pattern.
