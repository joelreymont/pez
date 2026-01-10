---
title: Improve error messages with context
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-10T06:38:01.611243+02:00\""
closed-at: "2026-01-10T12:06:38.209816+02:00"
---

File: src/main.zig, src/decompile.zig. Current: Errors show stack trace but not which opcode/offset failed. Implementation: 1) Add error context struct with (file, offset, opcode, block_id), 2) Wrap errors with context in processBlockWithSim, 3) Print context in main error handler (e.g., 'Error at offset 42 (LOAD_METHOD): NotAnExpression'). Priority: P3-LOW. Quality of life for debugging.
