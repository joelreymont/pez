---
title: Fix BigInt shift overflow
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T12:47:13.520781+02:00\""
closed-at: "2026-01-17T12:47:18.670260+02:00"
close-reason: completed
---

Full context: src/pyc.zig:70-110. Cause: BigInt.toI64/toI128 used narrow shift counters, overflowed when digits len large (panic in _pydecimal). Fix: widen shift, check available bits before shifting, cast shift amounts.
