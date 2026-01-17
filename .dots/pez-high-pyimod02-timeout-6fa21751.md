---
title: [HIGH] pyimod02 timeout
status: open
priority: 1
issue-type: task
created-at: "2026-01-17T08:34:13.026030+02:00"
---

pyimod02_importers.pyc decompile >35s; sample shows decompile.Decompiler.init + stack.cloneStackValue hotspots. Need perf redesign: reduce per-code init cost, cache/stream stack flow, avoid heavy clone in initStackFlow (src/decompile.zig:543, src/stack.zig:1100).
