---
title: Fix augmented assignment operators
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T07:21:22.107951+02:00"
---

x += 5 shows as x = x + 5. Need to detect BINARY_OP followed by STORE to same var and emit AugAssign.
