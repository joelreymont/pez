---
title: Add Python 2.x DELETE_SLICE handlers
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:01:08.180446+02:00"
---

Files: src/stack.zig (add DELETE_SLICE_0/1/2/3 cases)
Change: Implement DELETE_SLICE_* opcodes for Python 2.x
- DELETE_SLICE_0: del x[:]
- DELETE_SLICE_1: del x[i:]
- DELETE_SLICE_2: del x[:j]
- DELETE_SLICE_3: del x[i:j]
- Similar to STORE_SLICE but generate delete AST node
Verify: Create Python 2.x test with del slice operations
