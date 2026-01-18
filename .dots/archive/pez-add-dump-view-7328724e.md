---
title: Add dump view tool
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T07:55:36.564814+02:00\\\"\""
closed-at: "2026-01-18T07:57:26.049579+02:00"
close-reason: completed
---

Full context: need CLI to dump bytecode/cfg/passes/patterns/blocks for pyc debugging; currently only dump.py writes raw JSON. Fix: add tools/dump_view.py to select code path + block, output filtered JSON; add skill 'dump' with triggers and commands.
