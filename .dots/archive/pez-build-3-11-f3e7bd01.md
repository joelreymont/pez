---
title: Build 3.11+ despecialization
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T09:29:24.772251+02:00\""
closed-at: "2026-01-16T10:16:19.322153+02:00"
---

Map all specialized opcodes to base (BINARY_OP_*, LOAD_ATTR_*, etc → base opcodes). Strip CACHE entries. Document inline cache sizes. Files: likely src/bytecode.zig or new src/despecialize.zig. Dependencies: none. Verify: 3.11+ bytecode compares correctly after despecialization.
