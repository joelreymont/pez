---
title: [HIGH] Expr equality
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-17T09:03:38.268523+02:00\""
closed-at: "2026-01-17T09:28:06.199309+02:00"
close-reason: completed
---

File: src/decompile.zig:419-455, src/ast.zig:179-546. Root cause: stackValueEqual compares expr pointers; merges mark equal exprs as unknown. Fix: implement ast.exprEqual/constantEqual and use in stackValueEqual+sameExpr. Why: preserves stack precision, improves decompile correctness.
