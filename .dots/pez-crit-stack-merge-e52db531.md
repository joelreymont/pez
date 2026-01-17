---
title: [CRIT] stack merge phi
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T22:12:25.810890+02:00"
---

Full context: src/decompile.zig:371. Cause: mergeStackEntry collapses mismatched stack values to .unknown, losing value identity across control-flow joins. This later turns into '__unknown__' in AST. Fix: implement stack-SSA/value numbering with explicit phi nodes for stack slots; propagate through expression building and codegen; do not materialize unknown identifiers.
