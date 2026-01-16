---
title: Implement 3.11+ call protocol opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:25.996078+02:00"
---

Add RESUME, PUSH_NULL, PRECALL, CALL, KW_NAMES handlers in stack.zig. Reconstruct function calls from 3.11+ bytecode. Files: src/stack.zig. Dependencies: none. Verify: 3.11+ function calls decompile correctly.
