---
title: Implement LOAD_ATTR/STORE_ATTR/DELETE_ATTR
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:37.449937+02:00"
---

Files: src/stack.zig
Change: Implement attribute access opcodes
- LOAD_ATTR: pop object, push attr value
- STORE_ATTR: pop value and object, store
- DELETE_ATTR: pop object, delete attr
- LOAD_SUPER_ATTR (3.12+): super() attribute
Verify: Decompile test with obj.attr, obj.x = 5, del obj.y
