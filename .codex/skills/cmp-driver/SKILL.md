---
name: cmp-driver
description: Decompile + compare + locate mismatch in one command.
---

# Compare Driver

## Triggers
- "compare driver", "cmp driver", "one-shot compare", "decompile+compare+locate"

## Command
```bash
tools/compare/compare_driver.py --orig <file.pyc> --pez ./zig-out/bin/pez --py python3.9 --xdis-python /tmp/pycenv/bin/python --path <code.path>
```

## Notes
- Add `--focus=<path>` only for quick text inspection; full compare needs full module.
