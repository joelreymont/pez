---
title: Add decompileTypeParamWrapper function
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:47:23.617393+02:00\""
closed-at: "2026-01-16T13:51:46.679807+02:00"
---

src/decompile.zig: New function to handle type param wrappers.
- Simulate wrapper bytecode
- Extract TypeVar names from CALL_INTRINSIC_1 INTRINSIC_TYPEVAR (id=7)
- Find inner MAKE_FUNCTION that creates actual function
- Return function_obj with type_params populated
- Depends: CALL_INTRINSIC_1 handler, TypeParam AST
- Verify: zig build test
