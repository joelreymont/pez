# PLAN

## Scope

- Make boat_main decompilation + round-trip parity the immediate delivery target.
- Keep all plan execution trackable via dot IDs and checkbox status.
- Use uv-managed runtimes only for compare/parity workflows.
- Fold prior `docs/testing-plan.md` content into this file as the only active plan.

## Current Baseline (2026-02-07)

- Dataset: `/Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted`
- Latest suite artifact: `/tmp/pez-boatmain-suite-20260207.json`
- pez decompile: `ok=329`, `error=0`
- pez compare: `exact=206`, `close=75`, `mismatch=48`, `error=0`
- decompyle3 decompile: `ok=329`, `error=0`
- decompyle3 compare: `exact=8`, `close=0`, `mismatch=321`, `error=0`

## Plan-Tracking Setup

- [ ] Merge testing plan into PLAN [dot:pez-merge-testing-plan-dc61ae79]
- [ ] Add PLAN checklist with dot IDs [dot:pez-add-plan-checklist-7554f7e3]
- [ ] Sync dot tree to checklist [dot:pez-sync-dot-tree-b96bfee9]
- [ ] Rebaseline boat_main metrics in PLAN [dot:pez-rebaseline-boat-main-4fc4b54c]
- [ ] Create detailed mismatch implementation dots [dot:pez-create-detailed-mismatch-84522086]

## Runtime / Tooling Standardization (uv-only)

- [x] Provision uv venvs [dot:pez-add-uv-venv-48730f83]
- [x] Clone decompyle3 refs [dot:pez-clone-decompyle3-refs-d4d268cf]
- [x] Prefer `.uv/py39` in compare tools [dot:pez-wire-uv-paths-d4ef838b]
- [x] Prefer `.uv/py312` in parity harness [dot:pez-wire-uv-paths-7201a0db]

## Boat_main Parity Execution

- [ ] Record current boat_main baseline [dot:pez-record-curr-boat-ccb838bb]
- [ ] Drain remaining boat_main mismatches [dot:pez-drain-remaining-boat-615a5db9]

### Active mismatch subtree (small-dot implementation)

- [ ] Repro pycparser lex mismatch [dot:pez-repro-pycparser-lex-3890f864]
- [ ] Locate lex first divergence [dot:pez-locate-lex-first-ffcd9e45]
- [ ] Patch lex divergence root cause [dot:pez-patch-lex-divergence-64271ce3]
- [ ] Add lex regression fixture+snapshot [dot:pez-add-lex-regression-af236d63]
- [ ] Validate lex fix and update suite [dot:pez-validate-lex-fix-5db7d8d9]

### Historical fixes already shipped

- [x] Aioice mismatch fix [dot:pez-fix-mismatch-aioice-2d93d276]
- [x] Telebot mismatch fix [dot:pez-fix-mismatch-telebot-a5980562]
- [x] Tarfile mismatch fix [dot:pez-fix-mismatch-tarfile-0672b1b8]
- [x] Glob mismatch fix [dot:pez-fix-mismatch-glob-cc594e91]
- [x] Subprocess mismatch fix [dot:pez-fix-subprocess-parity-39c6f674]
- [x] Bootsubprocess mismatch fix [dot:pez-fix-mismatch-bootsubprocess-435a9715]

## Regression Hardening

- [ ] Recheck listComprehensions crash regression [dot:pez-recheck-listcomprehensions-eb9cf738]
- [ ] Recheck loops2 hang regression [dot:pez-recheck-loops2-hang-76a44e45]

## Test Hardening (merged from docs/testing-plan.md)

- [ ] Expand snapshot coverage matrix [dot:pez-expand-snapshot-coverage-c98b2e59]
- [ ] Expand property invariants [dot:pez-expand-prop-invariants-d1dac452]
- [ ] Wire version-matrix parity runs [dot:pez-wire-ver-matrix-5a7c1df8]

### Snapshot coverage targets

- [ ] Functions: decorators/defaults/kwdefaults/annotations/closures [dot:pez-expand-snapshot-coverage-c98b2e59]
- [ ] Classes: build-class/metaclass paths [dot:pez-expand-snapshot-coverage-c98b2e59]
- [ ] Control-flow: if/loop/try/with/match variants [dot:pez-expand-snapshot-coverage-c98b2e59]
- [ ] Expressions: ternary/comprehensions/chained-compare/f-string [dot:pez-expand-snapshot-coverage-c98b2e59]
- [ ] Version-specific opcode delta snapshots [dot:pez-expand-snapshot-coverage-c98b2e59]

### Property invariant targets

- [ ] Decoder invariants in `src/property_tests.zig` [dot:pez-expand-prop-invariants-d1dac452]
- [ ] Opcode-table invariants in `src/property_tests.zig` [dot:pez-expand-prop-invariants-d1dac452]
- [ ] CFG invariants in `src/property_tests.zig` [dot:pez-expand-prop-invariants-d1dac452]
- [ ] Stack simulation invariants in `src/property_tests.zig` [dot:pez-expand-prop-invariants-d1dac452]
- [ ] Decompiler invariants in `src/property_tests.zig` [dot:pez-expand-prop-invariants-d1dac452]
- [ ] Marshal invariants in `src/property_tests.zig` [dot:pez-expand-prop-invariants-d1dac452]

## Final Gate

- [ ] Run final parity gate [dot:pez-run-final-parity-590494c5]
  - `zig build test`
  - `python3 tools/compare/compare_suite.py --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted --py /Users/joel/Work/pez/.uv/py39/bin/python --xdis-python /Users/joel/Work/pez/.uv/py39/bin/python --decompyle3 /Users/joel/Work/pez/.uv/py39/bin/decompyle3 --out-root /tmp/pez-boatmain-suiteXX --out /tmp/pez-boatmain-suiteXX.json`
  - `bash tools/parity/run.sh`
- Ship criterion:
  - boat_main `mismatch=0`
  - decompyle3 compare run stable with `decompile error=0`

## Post-Parity Architecture

- [ ] Execute post-parity architecture backlog [dot:pez-exec-post-parity-a272c4af]
  - postdominator-driven merge/regioning
  - single authoritative control-flow pattern contract
  - expression/stack graph caching
  - staged pipeline (region -> expression -> statement -> canonicalize -> emit)

## Operating Rules

- One fix per commit (`jj describe -m "..."`), then `jj new`.
- Never close a dot before implementation + tests + commit.
- Use `dot` as execution source; keep PLAN checkboxes synchronized to dot status.
