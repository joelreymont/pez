---
title: Fix P0 memory leaks in decompiler
status: open
priority: 0
issue-type: task
created-at: "2026-01-16T10:51:39.417932+02:00"
---

Invalid free in decompileIfWithSkip when processing annotations.3.14.pyc. Likely double-free of base_vals in elif chain. File: src/decompile.zig:2996. Test: test/corpus/annotations.3.14.pyc
