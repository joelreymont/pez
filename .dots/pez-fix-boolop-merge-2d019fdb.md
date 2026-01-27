---
title: Fix boolop merge
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T12:29:56.363742+01:00"
---

Context: src/decompile.zig:18124; cause: chained compare/boolop snapshots show broken parentheses and structure; fix: align boolop merge with compare chain resolution; deps: Fix try merges; verification: zig build test -- --test-filter 'snapshot chained compare and 3.9'.
