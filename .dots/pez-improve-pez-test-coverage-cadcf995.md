---
title: Improve pez test coverage
status: open
priority: 2
issue-type: task
created-at: "2026-01-10T18:08:37.052345+02:00"
---

Working on improving decompiler test pass rate. Current: 149/190 passing.

Recent fixes:
- Added UNPACK_SEQUENCE support for tuple unpacking (src/decompile.zig:250-286)
- Added IS_OP and CONTAINS_OP handlers for Python 3.9+ (src/stack.zig:1489-1528)
- Added BINARY_SLICE/STORE_SLICE handlers for Python 3.12+ (src/stack.zig:2475-2500)
- Fixed empty tuple printing as [] for store context (src/codegen.zig:287-288)
- Fixed for loop unpacking targets including empty (src/decompile.zig:1744-1764)
- Added isNoneExpr helper to omit None in slice bounds (src/stack.zig:3382-3388)

Remaining failures (41/190):
- Compound ternary expressions with and/or conditions (conditional_expressions.3.9)
- List literal optimization: BUILD_LIST 0 + LOAD_CONST(tuple) + LIST_EXTEND pattern needs work
  - Issue: tuple from pyc.Object becomes Expr.tuple, not Constant.tuple
  - Need to check Expr.tuple instead of Constant.tuple in LIST_EXTEND handler at stack.zig:3081
- Various Python 2.x specific tests (2.5, 2.6, 2.7)
- Some if/elif patterns

Next step: Fix LIST_EXTEND to check Expr.tuple instead of Constant.tuple
