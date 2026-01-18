---
title: Fix if fallthrough
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T14:18:15.018095+02:00\\\"\""
closed-at: "2026-01-18T14:18:19.534880+02:00"
close-reason: completed
---

Full context: src/decompile.zig:2129, 3932, 3292, 8223. Cause: terminal-then ifs inside try produced else bodies and duplicated handler/commands; branchEnd crossed handler blocks. Fix: add br_limit, detect terminal-then fallthrough, set if_next override, and honor override in findIfChainEnd loops.
