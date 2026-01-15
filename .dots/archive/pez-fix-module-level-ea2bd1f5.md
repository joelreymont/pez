---
title: Fix module-level Python 3.14 comprehension decompilation
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-15T16:02:47.743070+02:00\\\"\""
closed-at: "2026-01-15T16:49:06.018094+02:00"
close-reason: "tryDecompileTryAsComprehension pre_stmts decompile fails because it tries to decompile setup block with empty stack. SWAP instruction expects 2 items. Original 2d7a00e code worked for module-level but failed for function-level (exit block issue). Commits between (d277fb8 CALL stack change) don't affect the comprehension simulation logic itself. Need different approach - maybe skip pre_stmts decompile for inline comprehensions"
---

Module-level list/dict/set comprehensions fail with StackUnderflow at SWAP opcode (offset 24). Root cause: commit d277fb8 'Add with statement support and fix CALL stack order' changed CALL stack handling, breaking comprehension simulation in tryDecompileInlineListComp at src/decompile.zig:2127. Working at 3286325, broken at d277fb8. Function-level comprehensions work (tests pass). Fix: Update comprehension simulation to match new CALL stack order or revert CALL changes.
