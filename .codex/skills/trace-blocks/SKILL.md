---
name: trace-blocks
description: Emit structured block traversal JSONL for a code path.
---

# Trace Blocks

## Triggers
- trace blocks
- block trace
- trace traversal

## Command
```bash
timeout 10 ./zig-out/bin/pez --trace-blocks --focus=<path> <file.pyc> > /tmp/decompiled.py 2> /tmp/block_trace.jsonl
```

## Notes
- combine with --trace-decisions for pattern choices
- increase timeout if needed
