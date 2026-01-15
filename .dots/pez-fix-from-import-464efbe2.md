---
title: Fix from import syntax
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T07:21:22.105013+02:00"
---

'from sys import path' becomes 'path = path'. Check IMPORT_FROM opcode handling in decompile.zig.
