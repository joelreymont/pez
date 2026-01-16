---
title: Build function_obj with type_params
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:51:40.444137+02:00"
---

src/decompile.zig:decompileTypeParamWrapper: Assemble result.
- Create FunctionValue from inner code
- Populate type_params from extracted TypeVars
- Return as StackValue.function_obj
- Depends: find inner function, TypeParam AST
- Unblocks: pep_695_type_params.3.14.pyc
- Verify: ./zig-out/bin/pez test/corpus/pep_695_type_params.3.14.pyc
