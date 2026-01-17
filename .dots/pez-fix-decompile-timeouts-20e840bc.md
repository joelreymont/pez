---
title: Fix decompile timeouts
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T20:54:08.909837+02:00"
---

Full context: src/decompile.zig:~6370 decompileStructuredRangeWithStack may loop/slow; timeouts on /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/ftplib.pyc and picamera2/encoders/multi_encoder.pyc. Cause: pathological CFG or infinite loop. Fix: add time/iteration guard, diagnose hotspots, and correct control-flow traversal; add regression/benchmark.
