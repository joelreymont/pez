---
title: [HIGH] sim-error-mask
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T21:32:48.028084+02:00\""
closed-at: "2026-01-16T21:58:26.205485+02:00"
close-reason: completed
---

Full context: src/decompile.zig:2665 ignores sim errors (catch {}), violating no-error-masking and risking corrupted stack state. Fix: plumb errors up or convert to explicit InvalidStack path with context.
