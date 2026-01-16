---
title: Add is_first_case param to decompileMatchCase
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:51:27.909662+02:00"
---

src/decompile.zig:decompileMatchCase: Add parameter.
- Add is_first_case: bool parameter
- First case has COPY opcode, others don't
- Depends: none
- Verify: zig build
