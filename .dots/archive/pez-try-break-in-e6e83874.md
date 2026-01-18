---
title: Try break in loop
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T15:03:46.996043+02:00\\\"\""
closed-at: "2026-01-18T15:08:57.590305+02:00"
close-reason: completed
---

Full context: src/decompile.zig:9608-9634 + 9678-9692, try normal path jumps outside loop so break missing in decompiled while; fix: tryNeedsBreak/appendTryBreak add break inside try and stop loop body when next_block leaves loop.
