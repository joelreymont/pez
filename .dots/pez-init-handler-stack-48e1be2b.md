---
title: Initialize handler stack with exception values
status: open
priority: 1
issue-type: task
created-at: "2026-01-15T18:11:06.219682+02:00"
blocks:
  - pez-fix-stackunderflow-in-9b5bdbf8
---

src/decompile.zig:4402 decompileHandlerBody - modify to:
1. Create init_stack with 3 .unknown markers for exception info
2. Call decompileBlockRangeWithStack instead of processBlockStatements
3. Or pass init_stack to SimContext before processing
Pattern: const exc_stack = &[_]StackValue{ .unknown, .unknown, .unknown };
