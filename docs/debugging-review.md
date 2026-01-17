# Debugging Tooling Review

## Current Additions
- `--dump` JSON for bytecode/cfg/dom/loops/patterns/passes.
- `tools/dump.py` wrapper to split JSON into per-section files.
- `debug-dump` Codex skill to drive the dump workflow.

## Missing Tools (Comprehensive)
- Bytecode decode detail: line table, exception table, cache entries, adaptive opcode history.
- Stack sim trace: per-instruction stack before/after, depth deltas, underflow provenance.
- Block ownership trace: which pass claimed each block and why, with timestamps.
- Pass timeline: ordered pass list with duration, allocations, and invalidation causes.
- Pattern audit: score + evidence + rejection reason for each candidate pattern.
- Dominator/postdominator dumps: trees + immediate doms + loop-nesting depth.
- CFG exports: DOT/JSON with edge types, handler edges, and loop headers.
- IR dumps: structured IR with stable IDs, source offsets, and SSA-like temps.
- Codegen trace: emit log of statements with originating IR and bytecode offsets.
- Roundtrip diff: normalized bytecode diff (opcode/arg, jump targets, line spans).
- Error provenance: stable error ID + opcode + offset + block + pass + stack top.
- Corpus runner: per-file artifact bundle (dump, decompile, compare, perf).
- Invariant checks: stack depth bounds, merge dominance, handler edges, loop latches.
- Coverage map: which opcodes/patterns were exercised by corpus.

## Redesign for Debuggability + Correctness
- Stage pipeline: decode -> cfg -> dom -> normalize -> pattern -> structured IR -> codegen.
- Pass manager: explicit stage registry, per-pass caches, invalidation tracking.
- Stable IR: typed nodes for if/while/for/try/with/match with source spans.
- Stack model: block-local stack-in/out states tracked and validated every pass.
- Deterministic traversal: explicit order and ownership rules; no double-emits.
- Pattern scoring: collect evidence for each pattern; choose max confidence.
- Merge validation: use dom/postdom and edge types to assert merge points.
- Exception regions: explicit handler ranges with entry/exit boundaries.
- Loop model: preheader/header/body/latch with normalized guards.
- Error model: typed error unions with stage context; no masking.
- Debug hooks: structured events for each stage with opt-in dump scopes.

## Tooling Plan (Immediate)
- Add `--dump-stack` for stack trace snapshots.
- Add `--dump-ir` for structured IR JSON.
- Add `--dump-trace` for per-pass events + timing.
- Add `--dump-cfg-dot`/`--dump-dom-dot` for graph visuals.
- Extend `tools/dump.py` to emit stage artifacts into per-file dirs.
