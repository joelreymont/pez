---
title: Identify elif allocation owner
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:54:55.117746+02:00"
---

src/decompile.zig: Trace ownership.
- Find where double-freed expr is allocated
- Determine if arena or gpa allocated
- Check if ownership transfers correctly in elif recursion
- Output: root cause identified
