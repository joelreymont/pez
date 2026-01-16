---
title: Handle function_obj in handleCall
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:47:16.526552+02:00"
---

src/stack.zig:handleCall line 886: Add .function_obj case.
- Check if code.name starts with '<generic parameters of '
- If so: call decompileTypeParamWrapper to extract inner func + type params
- Return function with type_params attached
- Depends: TypeParam AST, CALL_INTRINSIC handlers
- Verify: ./zig-out/bin/pez test/corpus/pep_695_type_params.3.14.pyc
