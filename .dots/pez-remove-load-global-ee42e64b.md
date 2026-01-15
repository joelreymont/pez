---
title: Remove LOAD_GLOBAL from global detection
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:29:10.705873+02:00"
---

Files: src/decompile.zig:5293
Issue: Spurious 'global print' in test_class_method_py3.3.7.pyc
Root cause: LOAD_GLOBAL triggers global declaration incorrectly
Fix: Change 'if (opcode == .STORE_GLOBAL or opcode == .LOAD_GLOBAL)' to just STORE_GLOBAL
Test: ./zig-out/bin/pez test_class_method_py3.3.7.pyc has no 'global print'
