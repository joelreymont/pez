---
title: [LOW] bigint format
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T22:12:46.974994+02:00\""
closed-at: "2026-01-16T22:57:13.265079+02:00"
---

Full context: src/pyc.zig:150. Cause: BigInt.format uses page_allocator and masks allocation errors with catch return, violating error-handling rules and making formatting unreliable under OOM. Fix: switch to passed allocator or a fixed buffer; propagate allocation errors from append.
