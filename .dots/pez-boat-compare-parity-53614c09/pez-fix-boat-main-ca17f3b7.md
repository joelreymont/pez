---
title: Fix boat_main module fallthrough if
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-18T17:39:20.048874+02:00\""
closed-at: "2026-01-18T20:55:23.894421+02:00"
close-reason: "done: loop if merge fixed + regression test"
---

Full context: boat_main.pyc module if at offset 670/680; decompileIf in src/decompile.zig:4092-4380 still emits else in some cases; ensure merge_block removal only when forward; verify module-level fallthrough if removes else; add targeted regression test in test/corpus_src/.
