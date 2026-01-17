---
title: Handler body sim lenient (fix)
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:26:18.905294+02:00\""
closed-at: "2026-01-17T14:26:22.551205+02:00"
close-reason: completed
---

src/decompile.zig:7778-7783 set sim.lenient + allow_underflow in decompileHandlerBody to avoid ROT_FOUR underflows
