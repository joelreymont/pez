---
title: Implement POP_JUMP_*_IF_NONE opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:44.205254+02:00"
---

Files: src/decompile.zig
Change: Implement None-checking jump opcodes
- POP_JUMP_IF_NONE/NOT_NONE
- POP_JUMP_FORWARD_IF_NONE/NOT_NONE
- POP_JUMP_BACKWARD_IF_NONE/NOT_NONE
- Use for is None / is not None patterns
Verify: Decompile test with if x is None:
