---
title: Fix sim error masking
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T22:29:37.721654+02:00\\\"\""
closed-at: "2026-01-17T22:32:56.464519+02:00"
close-reason: completed
---

Context: src/decompile.zig:1864,1890,1893,1919,1923,1958,1961,2011-2023. Root cause: catch return null masks SimError -> silent wrong AST. Fix: propagate error union, add typed error (e.g. DecompileError.SimFailed) with opcode/offset context, update callers to handle.
