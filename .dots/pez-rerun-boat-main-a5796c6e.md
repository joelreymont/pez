---
title: Rerun boat_main compare
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T08:26:40.984498+02:00"
---

Full context: tools/compare/compare_dir.py and /private/tmp/pez_decompiled_boat4 outputs. Cause: compare summary outdated after fixes. Fix: re-run decompile_dir.py on boat_main pycs and compare_dir.py, update summary.json and plan, archive dot with results.
