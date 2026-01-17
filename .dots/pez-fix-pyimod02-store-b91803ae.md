---
title: Fix pyimod02 STORE_NAME underflow
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T20:53:59.865491+02:00"
---

Full context: src/stack.zig:4378 StackUnderflow at STORE_NAME when decompiling /Users/joel/Work/Shakhed/boat_main_extracted_3.9/pyimod02_importers.pyc (offset 186). Cause: stack effect mismatch for match/mapping sequence or missing init before STORE_NAME. Fix: correct opcode stack effect / block init and add regression test.
