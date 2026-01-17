---
title: [CRIT] Match obj errors
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T09:03:29.816140+02:00\""
closed-at: "2026-01-17T09:27:56.732336+02:00"
close-reason: completed
---

File: src/decompile.zig:5045-5065, 5163, 8727. Root cause: catch return null on constExprFromObj/alloc in keyExprsFromObj/attrNamesFromObj/defaults handling. Fix: return DecompileError!? and propagate with try; update callers. Why: avoid silent loss of match literal/kw defaults.
