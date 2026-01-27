---
title: for-setup-scan-depth
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T16:04:43.600207+01:00"
---

Full context: src/ctrl.zig:1466-1486; cause: fixed-size work/visited arrays can miss GET_ITER in deep predecessor chains; fix: use dynamic worklist/bitset sized to CFG blocks, add stress test.
