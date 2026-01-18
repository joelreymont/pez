---
title: Import alias for dotted
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T15:18:02.304751+02:00\\\"\""
closed-at: "2026-01-18T15:18:12.846848+02:00"
close-reason: completed
---

Full context: src/stack.zig:3707-3724, IMPORT_FROM after IMPORT_NAME with empty fromlist (dotted import alias) was mis-emitted as import_from; fix: detect dotted module + attr match and keep import_module for 'import pkg.sub as name'.
