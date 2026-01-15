---
title: Remove LOAD_GLOBAL from spurious global detection
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:59:14.158807+02:00"
---

Files: src/decompile.zig:5293
Change: Only generate 'global' declaration for STORE_GLOBAL, not LOAD_GLOBAL
- Current: if (inst.opcode == .STORE_GLOBAL or inst.opcode == .LOAD_GLOBAL)
- Fix: if (inst.opcode == .STORE_GLOBAL)
Verify: Decompile test_class_method_py3.3.7.pyc, should not have 'global print'
