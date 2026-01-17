---
title: Handler cleanup
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T17:16:50.189749+02:00\\\"\""
closed-at: "2026-01-17T17:16:57.402496+02:00"
close-reason: completed
---

Full context: src/decompile.zig:4365-4395; cause: except binding emits err=__exception__ and cleanup try/finally surfaces; fix: drop placeholder assignment when handler name known and unwrap empty finally wrapper.
