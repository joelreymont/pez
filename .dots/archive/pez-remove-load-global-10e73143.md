---
title: Remove LOAD_GLOBAL from global detection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:50:20.674837+02:00\""
closed-at: "2026-01-16T10:18:07.865406+02:00"
---

Files: src/decompile.zig:5293
Bug: LOAD_GLOBAL triggers 'global' declarations for reads (e.g., 'global print').
Fix: Remove 'or inst.opcode == .LOAD_GLOBAL' from condition, keep only STORE_GLOBAL.
Test: ./zig-out/bin/pez tests/compiled/test_class_method_py3.3.7.pyc should not show spurious 'global print'.
