---
title: Add hasInlineComprehension check
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:54:44.365611+02:00"
---

src/ctrl.zig: Add helper function.
- Check if block has LOAD_FAST_AND_CLEAR followed by BUILD_LIST
- Return bool
- Verify: zig build
