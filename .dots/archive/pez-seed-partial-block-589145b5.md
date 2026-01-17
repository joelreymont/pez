---
title: Seed partial block stack
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T12:34:28.790180+02:00\""
closed-at: "2026-01-17T12:34:32.967684+02:00"
close-reason: completed
---

Full context: src/decompile.zig:8320. Cause: processPartialBlock starts with empty stack, underflows when blocks depend on incoming stack values (e.g., if condition blocks). Fix: seed sim stack from stack_in[block.id] by cloning values before simulating.
