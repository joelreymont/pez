---
title: Fix exceptions block boundary
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:48:20.499607+02:00\""
closed-at: "2026-01-16T13:55:22.818009+02:00"
---

src/ctrl.zig or src/decompile.zig: Fix block processing order.
- exceptions.3.14.pyc fails at BINARY_OP offset 8
- Module-level try block processed with wrong initial state
- Check block creation and processing order
- Unblocks: exceptions.3.14.pyc
- Verify: ./zig-out/bin/pez test/corpus/exceptions.3.14.pyc
