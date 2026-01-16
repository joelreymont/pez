---
title: Build per-version opcode tables
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T09:29:23.858879+02:00\""
closed-at: "2026-01-16T10:49:09.424973+02:00"
---

Create opcode tables for Python 1.0-3.14 (each minor version). For each: list opcodes+numbers, stack effects, version-specific behavior. Build coverage matrix (implemented vs total). Files: likely new file src/opcode_tables.zig or similar. Dependencies: none. Verify: matrix shows per-version coverage.
