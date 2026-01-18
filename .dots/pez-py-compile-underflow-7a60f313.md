---
title: py_compile underflow
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T12:57:14.107553+02:00"
---

Full context: src/decompile.zig:9232 processPartialBlock + src/stack.zig:2423 simulate popN; py_compile.pyc decompile fails with StackUnderflow in try header handling. Fix: adjust try-body block handling to avoid simulating control-flow in prelude; add regression test.
