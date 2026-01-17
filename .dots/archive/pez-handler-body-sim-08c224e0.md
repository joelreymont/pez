---
title: Handler body sim lenient
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:24:14.234592+02:00\""
closed-at: "2026-01-17T14:24:24.616335+02:00"
close-reason: completed
---

src/decompile.zig:7771-7775 decompileHandlerBody should set lenient + allow_underflow to avoid ROT_FOUR underflows
