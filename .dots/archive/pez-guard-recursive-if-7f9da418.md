---
title: Guard recursive if cycles
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T14:40:30.689209+02:00\""
closed-at: "2026-01-17T14:40:34.723765+02:00"
close-reason: completed
---

src/decompile.zig:3586 add if_in_progress bitset to prevent decompileIfWithSkip recursion loops (cmd.pyc segfault)
