---
title: FOR_LOOP stack underflow in Python 1.x
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T20:40:34.848470+02:00\""
closed-at: "2026-01-15T20:49:32.638693+02:00"
---

src/stack.zig:3132, src/decompile.zig:2596. FOR_LOOP header block entered with empty stack. Root cause: CFG splits block at FOR_LOOP, predecessor state not transferred. Need to either: (1) merge stack state from predecessors in decompileBlock, or (2) ensure detectPattern handles header before decompileBlock, or (3) simulate predecessor in FOR_LOOP case. Test: refs/pycdc/tests/compiled/test_misc.1.5.pyc offset 123.
