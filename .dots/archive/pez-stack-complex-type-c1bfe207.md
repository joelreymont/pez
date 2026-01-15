---
title: Stack complex type cloning
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T16:54:50.599058+02:00\""
closed-at: "2026-01-15T16:55:04.119789+02:00"
---

stack.zig:360 - Handle tuples and code objects in stack value cloning. Recursively clone tuple elements, shallow clone code objects (immutable refs). Add frozenset support. Test: tuple constants, nested tuples, function defs in exprs.
