---
title: Implement IMPORT_NAME/IMPORT_FROM opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:38.063627+02:00"
---

Files: src/stack.zig
Change: Implement import opcodes
- IMPORT_NAME: import module
- IMPORT_FROM: from module import name
- IMPORT_STAR: from module import *
- Create Import/ImportFrom AST nodes
Verify: Decompile test with import sys, from os import path
