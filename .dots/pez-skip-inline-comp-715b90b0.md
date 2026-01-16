---
title: Skip inline comp in detectTryPattern
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:54:44.369343+02:00"
---

src/ctrl.zig:detectTryPattern: Use helpers.
- If hasInlineComprehension(protected) and isComprehensionCleanup(handler): return null
- Unblocks: comprehensions.3.14, generators.3.14, pep_709_comprehensions.3.14
- Depends: helper functions
- Verify: ./zig-out/bin/pez test/corpus/comprehensions.3.14.pyc
