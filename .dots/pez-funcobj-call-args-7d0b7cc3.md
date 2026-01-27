---
title: funcobj-call-args
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T16:04:39.857802+01:00"
---

Full context: src/stack.zig:1489-1501; cause: function_obj calls drop args/keywords, emitting empty call; fix: preserve args/keywords (convert function_obj to Expr or route through handleCallExpr) and add snapshot.
