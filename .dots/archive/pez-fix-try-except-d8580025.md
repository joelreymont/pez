---
title: Fix try/except/finally body
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T07:21:22.084696+02:00\\\"\""
closed-at: "2026-01-15T09:54:02.506680+02:00"
close-reason: "try body shows full code, except handler shows 'pass' - handler body missing"
---

Try blocks show only 'pass' - body statements missing. Check decompile.zig decompileTry function.
