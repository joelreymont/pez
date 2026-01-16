---
title: Fix match guard decompilation - multi-block pattern extraction
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-16T12:02:31.464490+02:00\\\"\""
closed-at: "2026-01-16T12:15:37.535768+02:00"
---

Pattern+guard spans blocks in Python 3.14. Block chain: N=MATCH_SEQUENCE, N+1=GET_LEN, N+2=UNPACK+STORE_FAST_STORE_FAST+guard. extractMatchPattern needs full instruction stream or multi-block sim. See /tmp/match_simple.pyc. Ref: src/decompile.zig:3800 decompileMatchCase, :4105 extractMatchPattern. Approach: collect insts from all pattern blocks before simulate, or pass block range to extractMatchPattern.
