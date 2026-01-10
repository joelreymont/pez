---
title: Implement function annotations (3.0+)
status: open
priority: 2
issue-type: task
created-at: "2026-01-10T06:37:48.129725+02:00"
---

File: src/decompile.zig (makeFunctionDef), src/stack.zig (MAKE_FUNCTION flags). Current: Function signatures extracted, annotations ignored. Opcodes: MAKE_FUNCTION flag 0x04 = annotations. Stack: Annotations tuple pushed before defaults. Implementation: 1) Check MAKE_FUNCTION flags for 0x04, 2) Pop annotations tuple, 3) Parse (arg_name: annotation) pairs, 4) Add to Arguments struct, 5) Generate in signature (def foo(x: int) -> str). Priority: P3-LOW. Rarely used in practice.
