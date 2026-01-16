---
title: Extract TypeVar names from wrapper bytecode
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:51:40.435950+02:00"
---

src/decompile.zig:decompileTypeParamWrapper: Scan for TypeVars.
- Iterate wrapper bytecode
- Find CALL_INTRINSIC_1 with arg=7 (TYPEVAR)
- Previous LOAD_CONST has TypeVar name string
- Collect names into []const u8 array
- Depends: skeleton, CALL_INTRINSIC_1 handler
- Verify: zig build test
