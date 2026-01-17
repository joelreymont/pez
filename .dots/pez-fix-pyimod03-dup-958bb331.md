---
title: Fix pyimod03 DUP_TOP underflow
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T20:54:04.274222+02:00"
---

Full context: src/stack.zig:2952 DUP_TOP StackUnderflow when decompiling /Users/joel/Work/Shakhed/boat_main_extracted_3.9/pyimod03_ctypes.pyc (offset 66). Cause: missing stack init in control-flow block (likely if/try). Fix: correct block init or simulate prelude; add regression test.
