---
name: stackflow-trace
description: Emit stack-flow propagation JSONL for a pyc.
---

# Stackflow Trace

## Triggers
- stackflow trace
- trace stackflow
- stack flow trace

## Command
```bash
timeout 20 ./zig-out/bin/pez --trace-stackflow --focus=<path> <file.pyc> > /tmp/decompiled.py 2> /tmp/stackflow.jsonl
```

## Notes
- remove --focus to trace full module (noisy)
- increase timeout for large code objects
