---
title: loop decision trace
status: open
priority: 2
issue-type: task
created-at: "2026-01-20T17:49:07.172937+02:00"
---

Full context: src/decompile.zig + tools/compare, cause: no persistent log of loop/guard/if rewrite decisions, fix: add JSONL trace tool consuming --trace-loop-guards and new trace file, why: prove control-flow rewrites.
