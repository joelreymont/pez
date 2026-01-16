---
title: Skip with cleanup in detectTryPattern
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:55:03.916217+02:00"
---

src/ctrl.zig:detectTryPattern: Skip with cleanup.
- If isWithCleanup(handler): return null or handle specially
- Unblocks: with_stmt.3.14.pyc
- Depends: isWithCleanup helper
- Verify: ./zig-out/bin/pez test/corpus/with_stmt.3.14.pyc
