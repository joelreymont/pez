---
title: [CRIT] Guard errors
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T09:03:24.856492+02:00\""
closed-at: "2026-01-17T09:27:51.256158+02:00"
close-reason: completed
---

File: src/decompile.zig:4583-4673, 4693-4707. Root cause: catch break/null in guardExprFromBlock/guardStartInBlock masks simulate/makeName failures. Fix: return DecompileError!? and propagate with try. Why: avoid silent guard drop that corrupts match decompile.
