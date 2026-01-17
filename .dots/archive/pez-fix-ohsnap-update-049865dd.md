---
title: Fix ohsnap update
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T16:56:39.069735+02:00\\\"\""
closed-at: "2026-01-17T16:56:50.645441+02:00"
close-reason: completed
---

Full context: deps/ohsnap/src/ohsnap.zig:214; cause: updateSnap uses writer with testing allocator instead of list allocator, causing invalid free; fix: use arena_allocator for writer.
