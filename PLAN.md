# Pez Plan: Boat_main Parity + UV Runtime Unification

## Scope

- Make boat_main decompilation and round-trip parity the active delivery target.
- Use uv-managed runtimes only for decompiler comparison and parity tooling.
- Drain all currently open boat_main mismatch dots to completion.
- Keep prior parity architecture work (postdom/pattern contract/pipeline) as follow-on phases after boat_main mismatch zeroing.

## Current Baseline

- Dataset: `/Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted`
- Latest suite baseline:
  - pez decompile: `ok=329`, `error=0`
  - pez compare: `exact=173`, `close=54`, `mismatch=102`
  - decompyle3 decompile: `ok=329`, `error=0`
- Known historical regressions to keep green:
  - `test_listComprehensions.2.7.pyc` (invalid free)
  - `test_loops2.2.2.pyc` (hang)
- Open execution dots:
  - `Fix mismatch aioice/mdns`
  - `Fix mismatch telebot/types`
  - `Fix mismatch tarfile`
  - `Fix mismatch subprocess`
  - `Fix mismatch packaging/specifiers`
  - `Fix mismatch typing`
  - `Fix mismatch picamera2/controls`
  - `Fix mismatch ftplib`
  - `Fix mismatch glob`

## Runtime Standardization (UV Only)

### Environments

- Python 3.9 runtime for compare/decompile loops:
  - `.uv/py39`
- Python 3.12 runtime for parity harnesses:
  - `.uv/py312`

### Installation Contract

- `uv python install 3.9`
- `uv python install 3.12`
- `uv venv -p 3.9 /Users/joel/Work/pez/.uv/py39`
- `uv venv -p 3.12 /Users/joel/Work/pez/.uv/py312`
- `uv pip install -p /Users/joel/Work/pez/.uv/py39 -e /Users/joel/Work/pez/refs/python-decompile3`
- `uv pip install -p /Users/joel/Work/pez/.uv/py39 xdis==6.1.7 spark-parser click configobj`
- `uv pip install -p /Users/joel/Work/pez/.uv/py312 uncompyle6 decompyle3 xdis`

### Tooling Defaults

- `tools/compare/compare_suite.py` must prefer:
  - `.uv/py39/bin/decompyle3`
  - `.uv/py39/bin/python`
- `tools/compare/lib.py` xdis interpreter detection must prefer:
  - `.uv/py39/bin/python`
- `tools/parity/run.sh` must use:
  - `.uv/py312` runtime
- Keep env override support (`PEZ_DECOMPYLE3`, interpreter flags) for explicit operator control.

## Boat_main Delivery Plan

## Phase 0: Preflight and Tracking

- Confirm repo state with `jj status`.
- Keep one ready mismatch dot at a time.
- Use compare suite output root progression (`suite18`, `suite19`, `suite20`, ...).
- Record every run summary in docs after meaningful movement.

## Phase 1: Aioice Root-Cause Fix

- Target unit: `<module>.MDnsProtocol.resolve`.
- Required method:
  - reproduce via `tools/compare/compare_driver.py`
  - localize with `tools/compare/locate_mismatch.py`
  - inspect unit signatures via `tools/compare/unit_trace.py`
- Fix style:
  - root-cause control-flow/body-range handling only
  - no cleanup suppression hacks or fallback masking
- Validation:
  - `compare_driver` exact on `aioice/mdns.pyc`
  - `zig build test`
  - `compare_suite` mismatch count decreases

## Phase 2: Ordered Mismatch Drain

- Apply the same loop for each open dot, in this order:
  1. `aioice/mdns`
  2. `telebot/types`
  3. `tarfile`
  4. `subprocess`
  5. `packaging/specifiers`
  6. `typing`
  7. `picamera2/controls`
  8. `ftplib`
  9. `glob`
- For each target:
  - add or update minimal fixture in `test/corpus_src/`
  - ensure compiled corpus fixture exists under `test/corpus/`
  - add regression test/snapshot
  - run `zig build test`
  - rerun targeted `compare_driver`
  - rerun global `compare_suite`
  - commit one fix per change (`jj describe -m "..."`, then `jj new`)

## Phase 3: Regression Hardening

- Re-run targeted historical crash/hang checks:
  - `test_listComprehensions.2.7.pyc`
  - `test_loops2.2.2.pyc`
- Add dedicated regressions if any instability appears.
- Ensure no silent error handling in changed code paths.

## Phase 4: Final Parity Gate

- Required final commands:
  - `zig build test`
  - `python3 tools/compare/compare_suite.py ...` (boat_main, uv paths)
  - `bash tools/parity/run.sh`
- Ship criterion:
  - boat_main `mismatch=0`
  - decompyle3 compare run stable with `decompile error=0`

## Follow-on Architecture Plan (Post Boat_main)

- Re-activate parity architecture backlog from prior plan:
  - postdominator-based merge and structure selection
  - single authoritative control-flow pattern contract
  - expression/stack graph caching
  - explicit staged pipeline (region, expression, statement, canonicalize, emit)
- Continue to gate by parity corpus and round-trip structural scores.

## Operational Rules

- Dot lifecycle:
  - do not close a dot until implementation + tests + commit are done
  - after `dot off`, start a fresh change (`jj new`) before next work unit
- Commit policy:
  - one fix/feature per commit
  - no unrelated batching
- Deletion policy:
  - use `trash` for cleanup/removals

## Verification Commands

```bash
zig build test

python3 tools/compare/compare_driver.py \
  --orig /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/aioice/mdns.pyc \
  --pez zig-out/bin/pez \
  --py /Users/joel/Work/pez/.uv/py39/bin/python \
  --xdis-python /Users/joel/Work/pez/.uv/py39/bin/python

python3 tools/compare/compare_suite.py \
  --orig-dir /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted \
  --py /Users/joel/Work/pez/.uv/py39/bin/python \
  --xdis-python /Users/joel/Work/pez/.uv/py39/bin/python \
  --decompyle3 /Users/joel/Work/pez/.uv/py39/bin/decompyle3 \
  --out-root /tmp/pez-boatmain-suiteXX \
  --out /tmp/pez-boatmain-suiteXX.json

bash tools/parity/run.sh
```

## Assumptions

- Boat_main on Python 3.9 is the primary parity corpus for immediate delivery.
- uv runtimes under `.uv/` are the only supported local compare/parity environments.
- `refs/python-decompile3` remains the pinned decompyle3 source of truth.
