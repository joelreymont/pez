---
title: Add TypeParam AST node
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:47:02.654148+02:00"
---

src/ast.zig: Add TypeParam struct.
- TypeParam = struct { name: []const u8, bound: ?*Expr, constraints: ?[]*Expr }
- Add type_params: ?[]const TypeParam to FunctionDef
- Add type_params: ?[]const TypeParam to ClassDef
- Verify: zig build test
