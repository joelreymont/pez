---
title: Merge reuse
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T06:54:35.292344+02:00\\\"\""
closed-at: "2026-01-18T07:18:14.688392+02:00"
close-reason: done
---

Full context: src/decompile.zig:593-639 mergeStackEntry allocates new array even when unchanged. Root cause: merge always builds fresh slice. Fix: detect identical merge and reuse existing; only allocate on change or use scratch. Why: reduce allocs in stack flow.
