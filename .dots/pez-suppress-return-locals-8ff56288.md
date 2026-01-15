---
title: Suppress return locals() in codegen
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:10:53.058501+02:00"
blocks:
  - pez-suppress-return-locals-5faeddfe
---

Either:
A) Filter out 'return locals()' statements in decompile.zig before emitting
B) Add flag to AST Stmt to mark as 'internal/suppress'
C) Post-process class body to remove trailing return
Test: test_class.2.5.pyc, test_docstring.2.5.pyc
