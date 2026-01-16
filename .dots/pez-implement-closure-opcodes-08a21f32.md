---
title: Implement closure opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:30.291357+02:00"
---

Add LOAD_CLOSURE, MAKE_CELL, LOAD_DEREF, STORE_DEREF, DELETE_DEREF handlers. Reconstruct closures correctly. Files: src/stack.zig. Dependencies: none. Verify: closure tests pass.
