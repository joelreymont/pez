---
title: Split pre-if statements
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T16:18:43.722610+02:00\\\"\""
closed-at: "2026-01-17T16:45:58.460125+02:00"
close-reason: completed
---

Full context: src/decompile.zig:7190 decompileStructuredRange treats any conditional block as pure if. Module blocks (e.g., zipfile.pyc block 16) contain many statements before the conditional jump, causing missing defs. Fix: detect statement opcodes before conditional, emit them via processPartialBlock, then decompile if with skip.
