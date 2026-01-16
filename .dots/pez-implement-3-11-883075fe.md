---
title: Implement 3.11+ exception opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:26.305927+02:00"
---

Add PUSH_EXC_INFO, CHECK_EXC_MATCH, RERAISE, PREP_RERAISE_STAR handlers. Parse 3.11+ exception table format. Files: src/stack.zig, src/exception.zig. Dependencies: none. Verify: 3.11+ try/except/finally and except* decompile.
