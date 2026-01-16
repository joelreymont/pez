---
title: Add codegen for all missing expression types
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:44.816981+02:00\""
closed-at: "2026-01-16T10:19:22.267691+02:00"
---

Files: src/codegen.zig
Change: Implement codegen for:
- lambda, await_expr, yield_expr, yield_from
- dict_comp, set_comp, generator_exp
- joined_str (f-strings), formatted_value
- if_exp, named_expr, subscript, starred
Each needs proper formatting and precedence
Verify: Round-trip tests for each expression type
