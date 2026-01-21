---
name: unit-min
description: Minimize a mismatching code object to a small repro.
---

# Unit Minimizer

## Triggers
- "minimize unit", "ddmin", "shrink repro", "min unit"

## Command
```bash
tools/compare/min_unit.py --orig <file.pyc> --pez ./zig-out/bin/pez --path <code.path> --py python3.9 --xdis-python /tmp/pycenv/bin/python --verify
```

## Notes
- Use `--out <path>` to keep minimized source.
