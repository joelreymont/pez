---
title: Seed if condition stack
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T13:14:30.137305+02:00\""
closed-at: "2026-01-17T13:14:59.969600+02:00"
close-reason: completed
---

Full context: src/decompile.zig:3410. Cause: decompileIfWithSkip simulated condition blocks with empty stack, causing underflows/corrupt base_vals (e.g., subprocess.pyc). Fix: seed sim with stack_in for condition block.
