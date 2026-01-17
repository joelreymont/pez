---
title: [HIGH] stack-codegen cycle
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T22:12:37.912607+02:00\""
closed-at: "2026-01-16T22:57:09.865076+02:00"
---

Full context: src/stack.zig:9 and src/codegen.zig:8. Cause: circular dependency (stack imports codegen and codegen imports stack) couples phases and blocks refactors. Fix: move Annotation type and signature extraction to a new shared module (e.g., src/signature.zig or src/annotations.zig), update both sides to depend on the shared module only.
