---
title: Handle INTRINSIC_TYPEALIAS in stack sim
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:47:30.748702+02:00"
---

src/stack.zig: Detect type alias pattern for CALL_INTRINSIC_1.
- When intrinsic id=11 (TYPEALIAS)
- Stack has (name, None, flags, evaluator_func) tuple
- Create TypeAlias statement
- Depends: TypeAlias AST, CALL_INTRINSIC_1 handler
- Verify: ./zig-out/bin/pez test/corpus/pep_695_type_params.3.14.pyc | grep 'type '
