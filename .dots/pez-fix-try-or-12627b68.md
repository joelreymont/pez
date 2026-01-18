---
title: Fix try OR merge
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T13:39:03.956446+02:00"
---

Full context: src/ctrl.zig:909, src/decompile.zig:2125. Cause: short-circuit OR used merge_block=then_block and branchEnd followed exception edges, duplicating raise after if. Fix: ignore exception edges in branchEnd; clear merge when is_elif and merge==then.
