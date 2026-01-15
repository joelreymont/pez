---
title: Implement ROT_*/DUP_* stack manipulation opcodes
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:43.591899+02:00"
---

Files: src/stack.zig
Change: Implement stack manipulation opcodes
- ROT_TWO: rotate top 2 items
- ROT_THREE: rotate top 3 items
- ROT_FOUR: rotate top 4 items
- DUP_TOP_TWO: duplicate top 2 items
- Needed for complex expressions
Verify: Run existing tests, should fix edge cases
