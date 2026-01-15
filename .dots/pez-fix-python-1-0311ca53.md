---
title: Fix Python 1.x-2.2 bytecode decoding
status: open
priority: 1
issue-type: task
created-at: "2026-01-15T18:12:46.059780+02:00"
---

Python 2.2 bytecode showing INVALID opcodes.
Root cause: Instruction encoding changed - Python 1.x-2.2 uses 1 or 3 byte instructions.
Python 2.3+ uses 2-byte instructions uniformly.
File: src/decoder.zig - need version-specific decoding.
Reference: Python/compile.c in CPython 2.2 source.
