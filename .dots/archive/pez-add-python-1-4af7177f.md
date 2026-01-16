---
title: Add Python 1.5-2.4 opcode tables
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:50:05.552195+02:00\""
closed-at: "2026-01-16T10:17:22.361948+02:00"
---

Files: src/opcodes.zig
Missing opcode tables for Python 1.5-2.4 causing panic on 1.5 files.
Create opcode_table_1_5 based on Python 2.2 opcodes (same set).
Add version checks in getOpcodeTable() for ver.gte(1,5) before ver.major==2.
Test: ./zig-out/bin/pez tests/xfail/*.1.5.pyc should not panic.
