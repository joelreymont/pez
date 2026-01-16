---
title: Fix elif expr ownership
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:54:55.120521+02:00"
---

src/decompile.zig:2997: Fix ownership.
- Either: don't free arena-allocated exprs
- Or: clone before recursive call
- Or: track ownership flag
- Unblocks: annotations.3.14.pyc
- Verify: ./zig-out/bin/pez test/corpus/annotations.3.14.pyc
