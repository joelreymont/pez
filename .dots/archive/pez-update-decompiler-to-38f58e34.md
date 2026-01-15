---
title: Update decompiler to emit else/finally
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T16:56:08.557006+02:00\\\"\""
closed-at: "2026-01-15T17:17:00.082879+02:00"
close-reason: updated decompileTry and decompileTry311 to use pattern fields
---

In src/decompile.zig, update try/except decompilation to use TryPattern.else_block and finally_block:
1. Find where TryPattern is consumed (likely in decompileStructured or similar)
2. Decompile else_block statements after handlers if non-null
3. Decompile finally_block statements after else if non-null
4. Verify AST generation includes else/finally clauses
Dependency: pez-detect-else-in-46dc8c63, pez-detect-finally-in-02b1f56a
Test: run pez on all try_*.pyc, verify output syntax.
