---
title: Trace elif double-free with GPA
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:54:55.114733+02:00"
---

Debug: Add GPA stack traces.
- Run pez with debug allocator on annotations.3.14.pyc
- Capture allocation/free stack traces
- Identify which expr is double-freed
- Output: file:line of bad free
- Verify: reproduces crash with trace
