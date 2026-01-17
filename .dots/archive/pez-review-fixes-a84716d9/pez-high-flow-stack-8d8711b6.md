---
title: [HIGH] Flow stack perf
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-17T09:03:43.082829+02:00\""
closed-at: "2026-01-17T09:28:10.162025+02:00"
close-reason: completed
---

File: src/decompile.zig:564-642, src/stack.zig:323-335, 923-950. Root cause: stack-flow clones/deinit deep values; no flow-mode. Fix: finalize flow_mode shallow deinit + cloneStackValueFlow usage in initStackFlow/merge. Why: reduce allocations, avoid timeouts.
