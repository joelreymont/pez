---
title: [HIGH] arraylist-unmanaged
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T21:32:52.609538+02:00"
---

Full context: Zig 0.15 rule requires ArrayList unmanaged; code uses std.ArrayList in core paths (e.g., src/decompile.zig:55, src/stack.zig:176, src/ctrl.zig:852). Fix: migrate to ArrayListUnmanaged and pass allocator to methods.
