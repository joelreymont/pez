---
title: Implement dict/set/generator comprehensions
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:04:42.059428+02:00\""
closed-at: "2026-01-16T10:17:53.267450+02:00"
---

Files: src/decompile.zig
Change: Detect comprehension patterns for dict/set/generator
- Similar to list comprehension detection
- LIST_APPEND → list comp (exists)
- SET_ADD → set comp
- MAP_ADD → dict comp
- Generator: YIELD_VALUE in comp
Verify: Decompile {x:y for x in z}, {x for x in y}, (x for x in y)
