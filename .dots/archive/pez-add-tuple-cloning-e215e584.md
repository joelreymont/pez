---
title: Add tuple cloning to stack
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T16:55:22.254684+02:00\""
closed-at: "2026-01-15T17:05:07.856298+02:00"
close-reason: Added tuple/code to Constant union, cloneTupleItems helper, writeConstant/printConstant tuple handling. Tests pass, tuple decompilation works.
---

In src/stack.zig:360 cloneConstValue(), add tuple case:
.tuple => |items| .{ .tuple = try cloneTupleItems(self.allocator, items) }
Implement cloneTupleItems() helper that recursively clones array of Objects.
Test: create tuple_const.py with (1, 2, 3), nested ((1, 2), (3, 4)), verify decompilation.
