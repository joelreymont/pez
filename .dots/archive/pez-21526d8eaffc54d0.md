---
title: Implement ternary decompilation
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-09T07:36:00.542079+02:00\\\"\""
closed-at: "2026-01-09T07:40:04.581580+02:00"
close-reason: completed
---

Files:
- src/decompile.zig: decompile loop (`decompile` ~80-160), block range (`decompileBlockRange` ~210), block processing (`processBlockWithSim` ~150), new ternary helpers (simulate branch + merge).
- src/ctrl.zig: `detectTernary` (~230) already detects ternary CFG shape.
- src/stack.zig: POP_JUMP handling (~2445) and stack cloning helpers.
- src/snapshot_tests.zig: add snapshot for `x = 1 if a else 2`.

Root cause: ternary pattern exists in CFG analyzer but decompiler ignores it, so conditional blocks get treated as statements. Current in-progress ternary logic causes a stack underflow in `processBlockWithSim` because the merge block expects an expression on the stack, but branch blocks were skipped without pushing the if-exp result into the merge simulation.

Fix plan:
- In `src/decompile.zig`, detect ternary in sequential/block-range paths before `decompileBlockInto`.
- Simulate condition block up to the conditional jump, capture condition expr and clone the remaining stack state.
- Simulate true/false blocks in isolated sims that start from the cloned stack; require each branch to produce exactly one expr and reject if any statement-producing opcode is encountered.
- Build `ast.if_exp` and push it onto a merge simulator seeded with the base stack, then process the merge block with `processBlockWithSim`.
- Ensure cleanup on error: deinit cloned stack values and branch expressions; do not consume stack entries when bailing out.
- Add snapshot test for module bytecode representing `x = 1 if a else 2` (3.10) and keep output stable.

Expected outcome: ternary expressions render as a single assignment and no stack underflows in `processBlockWithSim`.
