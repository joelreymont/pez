---
title: Add code object cloning to stack
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T16:55:27.195906+02:00\""
closed-at: "2026-01-15T17:05:30.085009+02:00"
close-reason: Code already handled. Frozenset not needed (uses set expr). Stack cloning complete.
---

In src/stack.zig:360 cloneConstValue(), add code object case:
.code => |c| .{ .code = c }  // shallow clone (immutable)
Add frozenset case:
.frozenset => |items| .{ .frozenset = try cloneFrozensetItems(self.allocator, items) }
Test: create nested_func.py with lambda in expression, frozenset constant.
