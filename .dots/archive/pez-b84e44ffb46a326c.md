---
title: modify
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-09T18:31:08.217749+02:00\""
closed-at: "2026-01-09T18:31:55.313421+02:00"
---

Progress: Exception handler offsets converted to byte offsets (*2 for 3.11+). CFG splits blocks at handler offsets. Successors allocated/freed correctly. Crash still occurs after adding successors, during predecessor update for block 3->handler 4. Issue: accessing cfg.blocks[hid].predecessors after modifying blocks array? Need to investigate if blocks array is being reallocated during iteration. Next: add debug to predecessor allocation, check if accessing stale pointer.
