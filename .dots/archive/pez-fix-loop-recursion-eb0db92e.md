---
title: Fix loop recursion
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-17T15:00:46.601900+02:00\""
closed-at: "2026-01-17T15:17:30.615675+02:00"
close-reason: completed
---

Full context: src/decompile.zig:8026-8200, decompileFor/decompileForBody recursing on nested for patterns causing segfaults (rc 139) on concurrent/futures/process.pyc and psutil/__init__.pyc; add guard to prevent re-entering same loop header/body or detect self-recursive pattern; prove with compare run.
