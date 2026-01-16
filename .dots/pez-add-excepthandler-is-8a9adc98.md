---
title: Add ExceptHandler.is_star field
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:46:40.408992+02:00"
---

src/ast.zig: Add is_star: bool to ExceptHandler struct.
- Distinguishes except* from except
- Required for codegen to emit correct syntax
- Depends: CHECK_EG_MATCH handler
- Verify: zig build test
