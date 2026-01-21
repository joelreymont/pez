---
name: loop-trace
description: Emit loop/decision trace JSONL for a pyc.
---

# Loop Decision Trace

## Triggers
- "loop trace", "decision trace", "trace guards", "trace decisions"

## Command
```bash
tools/compare/loop_decision_trace.py --orig <file.pyc> --pez ./zig-out/bin/pez --out /tmp/trace.json
```

## Notes
- Add `--trace-sim=<block>` to include sim steps in the trace.
