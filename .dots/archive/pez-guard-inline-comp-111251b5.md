---
title: Guard inline comp sim
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T07:41:58.064784+02:00\\\"\""
closed-at: "2026-01-18T07:53:00.614248+02:00"
close-reason: completed
---

Full context: src/decompile.zig:2574-2705 tryDecompileInlineListComp simulates bytecode; mimetypes.pyc fails with StackUnderflow while detecting inline comp (Error in MimeTypes at offset 20 STORE_NAME). Cause: inline comp detection sim errors propagate; false positives on BUILD_LIST patterns. Fix: return null on non-alloc SimError; tighten detection by requiring LIST_APPEND/SET_ADD/MAP_ADD in loop body before sim.
