---
title: Fix module-level statement skipping
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:25.688693+02:00"
---

Fix bug where initial assignments are skipped in is_op.3.9.pyc, contains_op.3.9.pyc, test_applyEquiv.2.5.pyc. Investigate why module statements not appearing. Files: src/decompile.zig or CFG construction. Dependencies: none. Verify: mentioned test files decompile with all statements.
