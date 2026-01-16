---
title: Debug elif memory corruption
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:47:52.101208+02:00\""
closed-at: "2026-01-16T13:55:22.810989+02:00"
---

src/decompile.zig:2997: Fix Invalid free in elif chains.
- Error: StackValue.deinit frees already-freed expr
- Occurs in recursive decompileIfWithSkip calls
- Debug with GeneralPurposeAllocator trace
- Likely: arena vs gpa allocation mismatch
- Unblocks: annotations.3.14.pyc
- Verify: ./zig-out/bin/pez test/corpus/annotations.3.14.pyc
