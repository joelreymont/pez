---
title: [CRIT] pending ternary
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T22:12:30.460582+02:00"
---

Full context: src/decompile.zig:515. Cause: global pending_ternary_expr and opcode-skip logic stitch expressions across blocks, indicating missing structured IR and causing fragile control-flow semantics. Fix: build a control-flow structured IR from CFG (region/structuring pass) and emit AST from that IR; remove pending_ternary_expr/pending_chain_targets cross-block state.
