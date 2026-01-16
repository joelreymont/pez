---
title: Fix with_stmt exception cleanup
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:48:13.659003+02:00\""
closed-at: "2026-01-16T13:55:22.814565+02:00"
---

src/decompile.zig or src/ctrl.zig: Handle with_stmt cleanup blocks.
- Similar to comprehension: cleanup has different stack state
- Skip or initialize cleanup block correctly
- Pattern: SWAP + STORE_FAST + context manager cleanup + RERAISE
- Unblocks: with_stmt.3.14.pyc
- Verify: ./zig-out/bin/pez test/corpus/with_stmt.3.14.pyc
