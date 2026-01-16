---
title: Suppress return locals() stmt
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:51.836533+02:00"
---

File: src/decompile.zig (statement generation)
When generating return statement:
- If pattern detected (LOAD_LOCALS + RETURN at end of Py2 class)
- Skip emitting the return statement
- Add comment explaining suppression
Dependencies: pez-detect-load-locals-5fbb9c85
Verify: zig build test
