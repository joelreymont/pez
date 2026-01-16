---
title: Extract guard expression from bytecode
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:43.297418+02:00"
---

File: src/decompile.zig (match case area)
For detected guard pattern:
- Decompile bytecode between LOAD_NAME and POP_JUMP_IF_FALSE
- Create expression AST for guard condition
- Store in MatchCase.guard field
Dependencies: pez-detect-guard-pattern-58859509
Verify: zig build test
