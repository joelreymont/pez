---
title: Fix legacy with ctx
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T08:33:56.359174+02:00\""
closed-at: "2026-01-17T08:34:00.453072+02:00"
close-reason: completed
---

src/decompile.zig:4160; SETUP_WITH often isolated in CFG; context_expr missing -> StackUnderflow. Simulate normal predecessor to capture context_expr; add test in src/test_with_legacy_snapshot.zig; ensure 3.9 pyc in test/corpus/with_legacy.3.9.pyc.
