---
title: Fix elif detection merge
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T16:06:52.824053+02:00\\\"\""
closed-at: "2026-01-17T16:07:34.760442+02:00"
close-reason: completed
---

Full context: src/ctrl.zig:837 detectIfPattern sets is_elif when else block is just fallthrough/merge. This collapses sequential ifs into elif chains, causing huge duplication in pycparser/ply/yacc.py (12k elif debug). Fix by only setting is_elif when else_block is not the merge block.
