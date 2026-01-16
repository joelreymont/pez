---
title: Add EXTENDED_ARG handling
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T09:29:24.466579+02:00\""
closed-at: "2026-01-16T10:16:15.365490+02:00"
---

Implement EXTENDED_ARG opcode for multi-byte argument encoding (all versions). Ensure argument size calculations correct per version. Files: src/bytecode.zig or opcode parsing. Dependencies: none. Verify: test files with large constants/jumps decompile correctly.
