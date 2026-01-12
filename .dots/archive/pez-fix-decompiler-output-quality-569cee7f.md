---
title: Fix decompiler output quality
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-11T16:07:50.978021+02:00\\\"\""
closed-at: "2026-01-11T16:28:17.925336+02:00"
---

Address formatting differences (quotes, parens) and recognize async for patterns instead of try/except with yield from

## Completed
- [x] Quote style: prefer single quotes unless string contains single quotes
- [x] Async for: fix use-after-free in setup_scan, search predecessors for SETUP_LOOP

## Remaining issues
- [ ] Chain assignments expanded (a = b = c = x becomes a = x; b = x; c = x)
- [ ] STORE_SUBSCR not generating output (a[0] = x missing)
- [ ] STORE_SLICE not generating output (a[1:2] = x missing)
- [ ] Comments from source not in bytecode (expected)
