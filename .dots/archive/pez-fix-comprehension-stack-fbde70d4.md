---
title: Fix comprehension stack state
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T15:29:34.715126+02:00\\\"\""
closed-at: "2026-01-15T15:45:55.837759+02:00"
close-reason: "Fixed: capture stack state from simulation and pass to exit block decompilation"
---

List comprehensions in 3.12+ wrapped in try/except need proper stack handling. tryDecompileInlineListComp must capture stack after simulation and pass to exit block decompilation. Issue: SWAP in exit block fails with StackUnderflow because exit block decompiled with empty stack. Root cause: simulation leaves [saved_var, list] on stack but we don't capture it. Location: src/decompile.zig:2164 tryDecompileInlineListComp, line 2251 exit block decompilation.
