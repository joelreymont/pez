---
title: Guard ternary sim errors
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T07:41:52.218922+02:00\\\"\""
closed-at: "2026-01-18T07:53:00.608576+02:00"
close-reason: completed
---

Full context: src/decompile.zig:1881-1985 simulateTernaryBranch/ConditionExpr/ValueExprSkip/BoolOpCondExpr propagate SimError; threading.pyc fails with StackUnderflow during tryDecompileTernaryInto (offset 462 STORE_NAME). Cause: optional ternary/boolop detection sim errors bubble up and abort decompile. Fix: treat non-alloc SimError as pattern-miss (return null) via helper; propagate OutOfMemory.
