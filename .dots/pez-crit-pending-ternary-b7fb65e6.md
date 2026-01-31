---
title: [CRIT] pending ternary
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T22:12:30.460582+02:00"
---

Full context: src/decompile.zig:515. Cause: global pending_ternary_expr and opcode-skip logic stitch expressions across blocks, indicating missing structured IR and causing fragile control-flow semantics. Fix: build a control-flow structured IR from CFG (region/structuring pass) and emit AST from that IR; remove pending_ternary_expr/pending_chain_targets cross-block state.

Dig protocol:
- Hypothesis: pending_ternary/pending_chain_targets are global cross-block state that should be replaced by explicit stack entry updates and local chain handling.
- Prediction: removing pending_ternary/pending_vals and feeding merge blocks via stack_in preserves ternary output and avoids cross-block state; local chain_targets keeps STORE_ATTR+UNPACK sequencing within a block.
- Falsification: if ternary snapshots regress or decompile fails to seed merge blocks, the approach is wrong.
- Evidence: src/sc_pass.zig saveExpr/saveTernary now call setStackEntryWithExpr; src/decompile.zig removed pending_ternary/pending_vals/pending_store_expr and uses local chain_targets; tests: `zig build test -Dtest-filter="snapshot if return else fallthrough"` and `zig build test -Dtest-filter="snapshot if elif else raise"`.
- Conclusion: Cross-block pending ternary/chain state removed; merge blocks are now seeded via stack_in, preserving ternary output; local chain targets keep correctness within block.
