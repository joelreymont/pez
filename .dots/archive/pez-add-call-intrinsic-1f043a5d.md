---
title: Add CALL_INTRINSIC_2 handler
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:46:06.821103+02:00\""
closed-at: "2026-01-16T13:57:37.237847+02:00"
---

src/stack.zig: Add handler for CALL_INTRINSIC_2 opcode.
- Pops 2 args, pushes .unknown result (net: -1)
- IDs: 1=PREP_RERAISE_STAR, 4=SET_FUNCTION_TYPE_PARAMS
- Depends: none
- Verify: zig build test
