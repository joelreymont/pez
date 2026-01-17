---
title: [CRIT] loop analysis
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T22:12:21.828448+02:00\""
closed-at: "2026-01-16T22:57:07.794707+02:00"
---

Full context: src/ctrl.zig:1744. Cause: loop membership and break/continue detection are based on approximate block ordering and heuristics (see isInLoop uses block_id < loop_header + 10). Fix: replace with dominator-based natural loop bodies (DomTree.loop_bodies), precompute block->loop membership, and use that for break/continue and enclosing loop queries; remove heuristics.
