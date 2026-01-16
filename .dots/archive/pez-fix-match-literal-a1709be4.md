---
title: Fix match literal case stack tracking
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:46:34.167193+02:00\""
closed-at: "2026-01-16T13:51:46.674930+02:00"
---

src/decompile.zig:decompileMatchCase: Handle Python 3.14 optimized match.
- First case has COPY, subsequent cases reuse subject on stack
- Add is_first_case parameter to track stack state
- Subject consumed by COMPARE_OP in subsequent cases
- Unblocks: pep_634_match.3.14.pyc
- Verify: ./zig-out/bin/pez test/corpus/pep_634_match.3.14.pyc
