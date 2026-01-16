---
title: Find inner function in wrapper
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:51:40.440316+02:00"
---

src/decompile.zig:decompileTypeParamWrapper: Locate MAKE_FUNCTION.
- Scan for MAKE_FUNCTION opcode
- Get code object from preceding LOAD_CONST
- Skip wrapper helper functions (like __annotate__)
- Depends: TypeVar extraction
- Verify: zig build test
