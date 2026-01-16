---
title: "P1: Suppress 'return locals()' in Python 2.x classes"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:48:48.011624+02:00\""
closed-at: "2026-01-16T06:49:33.735428+02:00"
---

src/decompile.zig - Detect LOAD_LOCALS + RETURN_VALUE pattern at end of class body, suppress output. Only for Python 2.x class code objects (flags 0x42). Spec: Phase 3
