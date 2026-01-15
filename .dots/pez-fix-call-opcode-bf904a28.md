---
title: Fix CALL opcode for class/decorator/nested func
status: active
priority: 2
issue-type: task
created-at: "\"2026-01-15T07:21:22.078089+02:00\""
---

NotAnExpression on CALL at module level. Issue: PUSH_NULL + LOAD_BUILD_CLASS pattern not recognized. Check stack.zig handleCall - callable is not an expression when it's a class builder. File: src/stack.zig:851
