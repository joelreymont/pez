---
title: Fix global/nonlocal declarations
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T07:21:22.102117+02:00\\\"\""
closed-at: "2026-01-15T10:26:01.418938+02:00"
close-reason: "Added nonlocal declaration output in decompileFunctionToSource (src/decompile.zig:5748-5795) - freevars emit 'nonlocal x' statements. Still have issue with <unknown> var names in assignments using STORE_DEREF - getDeref not finding names correctly"
---

Global/nonlocal declarations missing. These are in code.co_cellvars/co_freevars - need to emit declarations.
