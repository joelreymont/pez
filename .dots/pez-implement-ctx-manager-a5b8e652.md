---
title: Implement context manager opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:26.919559+02:00"
---

Add SETUP_WITH, WITH_CLEANUP, WITH_CLEANUP_START, WITH_CLEANUP_FINISH, BEFORE_WITH handlers (2.5-3.10). Add WITH_EXCEPT_START (3.11+). Files: src/stack.zig. Dependencies: none. Verify: with statements decompile for all versions.
