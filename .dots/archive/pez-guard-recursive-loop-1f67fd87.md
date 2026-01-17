---
title: Guard recursive loop decompile
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:44:29.778584+02:00\""
closed-at: "2026-01-17T14:44:33.366778+02:00"
close-reason: completed
---

src/decompile.zig:7988 add loop_in_progress guard to decompileFor to avoid infinite recursion (process.pyc segfault)
