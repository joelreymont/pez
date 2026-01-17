---
title: If base owned
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T17:23:14.875042+02:00\\\"\""
closed-at: "2026-01-17T17:23:23.102230+02:00"
close-reason: completed
---

Full context: src/decompile.zig:3669-3725; cause: decompileIfWithSkip used errdefer plus unconditional defer, double-freeing base_vals on error; fix: track base_owned and clear after deinit.
