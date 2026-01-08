---
title: Convert composite LOAD_CONST to AST literals
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T18:06:51.417506+02:00\""
closed-at: "2026-01-08T19:14:22.821582+02:00"
close-reason: completed
---

File: src/stack.zig:155-172, 193-200 - objToConstant returns .none for tuple/list/set/dict/code constants, so LOAD_CONST loses structure. Use ast.Expr.list/tuple/dict/set (src/ast.zig:216-332) to build literal expressions from pyc.Object.{tuple,list,set,dict} recursively, and return stack values that preserve these literals.
