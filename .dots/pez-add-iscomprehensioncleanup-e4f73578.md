---
title: Add isComprehensionCleanup helper
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:54:44.361707+02:00"
---

src/ctrl.zig: Add helper function.
- Check if block has SWAP + POP_TOP + SWAP + STORE_FAST + RERAISE pattern
- Return bool
- Verify: zig build
