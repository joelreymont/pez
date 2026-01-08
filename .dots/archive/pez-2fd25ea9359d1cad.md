---
title: Implement 3.11+ cache skipping
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-07T17:38:17.472193+02:00\""
closed-at: "2026-01-08T06:38:23.186963+02:00"
---

File: src/decode.zig - 3.11+ has CACHE instructions after certain opcodes. Use opcode.cacheCount() to skip inline cache entries.
