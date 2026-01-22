---
name: dump-codepath
description: Dump cfg+patterns (+bytecode) for a code path in one JSON.
---

# Dump Codepath

## Triggers
- dump codepath / dump code path
- cfg+patterns / dump cfg patterns

## Command
`python3 tools/dump_codepath.py --pyc <file.pyc> --code-path <func> --out <dump.json>`

## Options
- `--sections bytecode,cfg,patterns`
- `--pez <path>` to override pez binary
- `--code-index N` if the code path appears multiple times
