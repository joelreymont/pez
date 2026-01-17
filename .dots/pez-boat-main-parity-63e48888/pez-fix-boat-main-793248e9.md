---
title: Fix boat_main.py empty
status: open
priority: 1
issue-type: task
created-at: "2026-01-17T11:18:30.444896+02:00"
---

Full context: /private/tmp/pez_decompiled_boat/boat_main.py empty; sys._MEIPASS usage missing. Trace decompile output for boat_main.pyc; fix missing control-flow/stack so codegen emits module body. Files: src/decompile.zig, src/codegen.zig.
