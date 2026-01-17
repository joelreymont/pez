---
title: Inline comp guard
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T13:17:33.786514+02:00\""
closed-at: "2026-01-17T13:17:40.567353+02:00"
close-reason: completed
---

Full context: src/decompile.zig:2510. Cause: tryDecompileInlineListComp propagated sim errors (StackUnderflow) and aborted decompile (dataclasses). Fix: treat simulate failures as non-comprehension and return null.
