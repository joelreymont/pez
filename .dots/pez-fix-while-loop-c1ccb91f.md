---
title: Fix while loop body decompilation
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T07:21:22.081455+02:00"
---

While loops show 'if cond: while cond: pass' instead of proper body. The body statements are lost. Check decompile.zig while pattern detection and body processing.
