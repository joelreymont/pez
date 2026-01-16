---
title: Add TypeAlias statement node
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:47:09.020049+02:00"
---

src/ast.zig: Add TypeAlias statement.
- TypeAlias = struct { name: []const u8, value: *Expr }
- Add type_alias case to Stmt union
- For 'type Point = tuple[float, float]' syntax
- Verify: zig build test
