---
title: dump codepath tool
status: open
priority: 2
issue-type: task
created-at: "2026-01-20T13:32:57.963295+02:00"
---

Full context: tools/dump_codepath.py: aggregate cfg+patterns (+bytecode) for a code path in one JSON. Cause: multi-step dump_view calls slow. Fix: wrapper script to emit combined JSON. Why: speed iterative control-flow inspection.
