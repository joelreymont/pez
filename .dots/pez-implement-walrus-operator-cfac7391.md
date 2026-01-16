---
title: Implement walrus operator detection
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:28.144272+02:00"
---

Detect walrus patterns in bytecode (CFG-based, not AST .named_expr). Reconstruct if (x := expr), while (x := expr), comprehension walrus. Files: src/expression.zig or src/decompile.zig. Dependencies: none. Verify: 3.8+ walrus tests pass.
