---
title: Fix loop try/except detection
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T11:26:49.837933+02:00\\\"\""
closed-at: "2026-01-18T11:40:23.357702+02:00"
close-reason: completed
---

Full context: src/ctrl.zig:983 detectTryPattern, src/decompile.zig:4420 decompileTry, src/decompile.zig:5850 detectPattern. Cause: functions like boat_main.run_bot lose try/except; orig bytecode has SETUP_FINALLY + exception handler but decompiled output is while True with no try/except (unit_diff /private/tmp/pez_compare_boat6_semantic/boat_main_run_bot.json). Fix: ensure try/except patterns inside loop bodies are detected and emitted; validate with unit_diff for <module>.run_bot and compare summary.
