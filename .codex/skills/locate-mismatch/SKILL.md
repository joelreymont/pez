---
name: locate-mismatch
description: Locate first bytecode mismatch and map to CFG blocks.
---

# Locate Mismatch

## Triggers
- locate mismatch / first mismatch / find divergence
- op diff with block id / mismatch offset

## Command
`python3 tools/compare/locate_mismatch.py --orig <orig.pyc> --src <decompiled.py> --path "<module>.func" --py <python> --out <report.json>`

## Options
- `--context N` for wider window
- `--code-path func` to override dump_view path
