---
title: Remove LOAD_GLOBAL from global detection
status: open
priority: 1
issue-type: task
created-at: "2026-01-15T18:10:53.051581+02:00"
blocks:
  - pez-fix-spurious-global-c133b473
---

src/decompile.zig:5293 - Change:
  if (inst.opcode == .STORE_GLOBAL or inst.opcode == .LOAD_GLOBAL)
To:
  if (inst.opcode == .STORE_GLOBAL)
Only STORE_GLOBAL requires 'global' declaration, not LOAD_GLOBAL.
Test: test_class_method_py3.3.7.pyc should not have 'global print'
