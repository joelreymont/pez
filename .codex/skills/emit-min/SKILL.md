---
name: emit-min
description: Minimize decompiled source while preserving a target code object.
---

# Emit Min

## Triggers
- emit min / minimize repro / ddmin
- shrink source for compare

## Command
`python3 tools/compare/emit_min.py --orig <orig.pyc> --src <decompiled.py> --path "<module>.func" --py <python> --out <min.py>`

## Options
- `--stats-out <stats.json>` for removed count
- `--max-iter N` to cap ddmin iterations
- `--index N` if the code path appears multiple times
