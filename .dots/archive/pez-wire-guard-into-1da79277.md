---
title: Wire guard into MatchCase AST
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:11:18.616709+02:00\""
closed-at: "2026-01-16T10:18:07.829836+02:00"
blocks:
  - pez-add-match-statement-31671795
---

src/decompile.zig - MatchCase creation:
1. Extract guard expression from bytecode
2. Set .guard field (currently null/TODO)
3. Verify codegen outputs 'case x if guard:' syntax
File: src/ast.zig has MatchCase with guard field
