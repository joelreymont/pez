---
title: Implement PEP 695 type parameters
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:27.834988+02:00"
---

Detect and reconstruct type parameter syntax for functions/classes (def func[T], class C[T]). Implement type statement (type Alias = ...). Files: src/annotations.zig or src/decompile.zig. Dependencies: none. Verify: 3.12+ type parameter tests pass.
