---
title: Add CALL_INTRINSIC_1 handler
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:46:00.988844+02:00\""
closed-at: "2026-01-16T13:57:37.234554+02:00"
---

src/stack.zig: Add handler for CALL_INTRINSIC_1 opcode.
- Pops 1 arg, pushes .unknown result (net: 0)
- IDs: 3=STOPITERATION_ERROR, 7=TYPEVAR, 11=TYPEALIAS
- Verify: zig build test
