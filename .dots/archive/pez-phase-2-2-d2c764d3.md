---
title: "Phase 2.2: Fix BUILD_CONST_KEY_MAP tuple check"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:48:06.153237+02:00\""
closed-at: "2026-01-16T10:18:55.903885+02:00"
---

src/stack.zig:3466 - Replace equality check with switch statement: switch (keys_val.expr.*) { .tuple => |t| { for (t.elts, 0..) |key, j| keys[j] = try ast.cloneExpr(self.allocator, key); }, else => { for (keys) |*k| k.* = null; } }
