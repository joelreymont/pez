---
title: Add decompileTypeParamWrapper skeleton
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:51:40.432243+02:00"
---

src/decompile.zig: Add empty function.
- fn decompileTypeParamWrapper(code: *CodeObject) !StackValue
- Return error.NotImplemented initially
- Depends: none
- Verify: zig build
