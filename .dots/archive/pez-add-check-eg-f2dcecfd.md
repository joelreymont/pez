---
title: Add CHECK_EG_MATCH handler
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:46:12.498968+02:00\""
closed-at: "2026-01-16T14:07:07.840726+02:00"
---

src/stack.zig: Add handler for CHECK_EG_MATCH opcode (except* matching).
- TOS=exception type, TOS1=exception group
- Push .unknown twice (non-matching, matching groups)
- Verify: zig build test
