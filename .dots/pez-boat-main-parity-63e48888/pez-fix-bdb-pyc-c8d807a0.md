---
title: Fix bdb.pyc hang
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T11:18:26.817623+02:00\\\"\""
closed-at: "2026-01-17T11:53:41.626502+02:00"
close-reason: completed
---

Full context: hang during decompile of /Users/joel/Work/Shakhed/boat_main_extracted_3.9/bdb.pyc; likely stack_flow growth or stack underflow. Inspect src/decompile.zig initStackFlow/decompileBlock, src/stack.zig stack sim. Add regression test from minimal source (no pyc in repo).
