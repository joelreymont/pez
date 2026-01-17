---
title: [CRIT] Decompile errors
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T09:03:20.217353+02:00\""
closed-at: "2026-01-17T09:27:45.092793+02:00"
close-reason: completed
---

File: src/decompile.zig:1727-1902. Root cause: catch return null in simulateTernaryBranch/Condition/Value/BoolOp/initCondSim masks SimError. Fix: propagate errors with try, keep null only for semantic non-match. Why: prevents silent wrong AST + aligns error policy.
