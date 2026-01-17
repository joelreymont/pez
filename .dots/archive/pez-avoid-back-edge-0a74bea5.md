---
title: Avoid back-edge merge in if chain end
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:34:20.794015+02:00\""
closed-at: "2026-01-17T14:34:23.607376+02:00"
close-reason: completed
---

src/decompile.zig:2895 findIfChainEnd should ignore merge_block that points back to condition block (loop back-edge)
