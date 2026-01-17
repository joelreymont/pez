---
title: Fix pyimod01 invalid free
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T20:53:54.147330+02:00\""
closed-at: "2026-01-17T08:34:06.578233+02:00"
close-reason: completed
---

Full context: src/decompile.zig:3084 decompileIfWithSkip double-free triggers Invalid free when decompiling /Users/joel/Work/Shakhed/boat_main_extracted_3.9/pyimod01_archive.pyc. Cause: ownership of base_vals exprs across elif path; deinit called twice. Fix: correct ownership/clone or adjust deinit path; add regression using pyimod01_archive.pyc.
