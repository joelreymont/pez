---
title: Fix future-import placement
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T12:06:32.717050+02:00\""
closed-at: "2026-01-29T09:26:26.926489+01:00"
---

Full context: SyntaxError in serial/win32.pyc (from __future__ import not at beginning). Ensure module docstring/future import ordering in decompile.zig/codegen.zig.
