---
name: unit-trace
description: Dump orig/compiled unit CFG signatures and diffs.
---

# Unit Trace

## Triggers
- "unit trace", "cfg diff", "block/edge diff", "trace unit"

## Command
```bash
tools/compare/unit_trace.py --orig <file.pyc> --src <decompiled.py> --path <code.path> --py python3.9 --xdis-python /tmp/pycenv/bin/python
```

## Notes
- Use `--index N` if the code path appears multiple times.
