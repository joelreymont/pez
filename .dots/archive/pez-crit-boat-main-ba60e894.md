---
title: [CRIT] boat-main timeout
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-17T06:39:18.920275+02:00\""
closed-at: "2026-01-18T20:55:23.904872+02:00"
close-reason: "done: no timeouts in decompile_dir"
---

Full context: boat_main.pyc decompile in ReleaseFast times out (>300s) and outputs empty file (/private/tmp/pez_decompiled_boat/boat_main.py). Cause: decompile path loops/allocates excessively; sample shows repeated decompileIfWithSkip/decompileStructuredRangeWithStack and heavy allocations in decompileTry/bitsets. Fix: eliminate pathological rescans/allocs, cache merge/try scans, reuse bitsets/queues, and ensure forward progress; verify decompile completes and file non-empty.
