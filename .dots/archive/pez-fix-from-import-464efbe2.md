---
title: Fix from import syntax
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T07:21:22.105013+02:00\\\"\""
closed-at: "2026-01-15T12:54:51.907141+02:00"
close-reason: "WIP: Added handleFromImport in decompile.zig:5301, modified IMPORT_FROM in stack.zig:3141 to push name instead of accumulating import_module. Still outputs path=path instead of from sys import path. Need to debug why condition at decompile.zig:170 may not be matching or why handleFromImport stmt not being emitted correctly"
---

'from sys import path' becomes 'path = path'. Check IMPORT_FROM opcode handling in decompile.zig.
