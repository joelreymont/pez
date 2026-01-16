---
title: Add isWithCleanup helper
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:55:03.912713+02:00"
---

src/ctrl.zig: Add helper function.
- Check if block matches with_stmt cleanup pattern
- Pattern: context manager __exit__ call + RERAISE
- Verify: zig build
