---
title: Emit type params in codegen
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:47:37.036060+02:00"
---

src/codegen.zig: Emit type parameter syntax.
- FunctionDef: 'def f[T, U: int]():'
- ClassDef: 'class C[T]:'
- TypeAlias: 'type Point = tuple[float, float]'
- Depends: TypeParam AST, TypeAlias AST
- Verify: ./zig-out/bin/pez test/corpus/pep_695_type_params.3.14.pyc
