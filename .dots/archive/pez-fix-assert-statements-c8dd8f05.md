---
title: Fix assert statements
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T07:21:22.099090+02:00\\\"\""
closed-at: "2026-01-15T10:07:19.410352+02:00"
close-reason: single asserts work; multiple asserts in sequence have issues
---

Assert shows as if/else instead of assert. Check for LOAD_ASSERTION_ERROR pattern in decompile.zig.
