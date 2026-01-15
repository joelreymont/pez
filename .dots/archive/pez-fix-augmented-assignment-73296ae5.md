---
title: Fix augmented assignment operators
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T07:21:22.107951+02:00\""
closed-at: "2026-01-15T14:37:09.753608+02:00"
close-reason: "Detect LOAD var + BINARY_OP + STORE var pattern in decompile.zig:775, emit AugAssign stmt instead of regular Assign when left operand name matches target"
---

x += 5 shows as x = x + 5. Need to detect BINARY_OP followed by STORE to same var and emit AugAssign.
