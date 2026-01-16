---
title: Fix exceptions block init
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:55:14.647931+02:00"
---

src/ctrl.zig or decompile.zig: Fix init.
- Ensure try body block starts with correct stack
- May need to skip NOP at try entry
- Unblocks: exceptions.3.14.pyc
- Depends: investigation dots
- Verify: ./zig-out/bin/pez test/corpus/exceptions.3.14.pyc
