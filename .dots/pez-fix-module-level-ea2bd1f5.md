---
title: Fix module-level Python 3.14 comprehension decompilation
status: open
priority: 1
issue-type: task
created-at: "2026-01-15T16:02:47.743070+02:00"
---

Module-level list/dict/set comprehensions fail with StackUnderflow at SWAP opcode (offset 24). Root cause: commit d277fb8 'Add with statement support and fix CALL stack order' changed CALL stack handling, breaking comprehension simulation in tryDecompileInlineListComp at src/decompile.zig:2127. Working at 3286325, broken at d277fb8. Function-level comprehensions work (tests pass). Fix: Update comprehension simulation to match new CALL stack order or revert CALL changes.
