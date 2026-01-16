---
title: Add Python 1.5-2.4 opcode tables
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:01:07.565429+02:00\""
closed-at: "2026-01-16T10:17:22.365952+02:00"
---

Files: src/opcodes.zig (getOpcodeTable function)
Change: Add version checks for Python 1.5-2.4 opcode tables
- Currently panics on Python 1.5-2.4 bytecode
- Need opcode definitions for these versions
- Reference existing 2.5+ and 3.x tables for structure
Dependency: Must complete after pez-fix-pyc-zig-4d337f3e (marshal parsing)
Verify: Decompile tests/xfail/*.1.5.pyc without panic
