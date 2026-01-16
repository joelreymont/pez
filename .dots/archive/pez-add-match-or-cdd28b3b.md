---
title: Add match OR patterns
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:01:09.717778+02:00\""
closed-at: "2026-01-16T10:19:22.222290+02:00"
---

Files: src/decompile.zig:3676-3800 (decompileMatch)
Change: Detect and extract OR patterns in match statements
- Pattern: case A | B | C:
- Bytecode may use JUMP_IF_FALSE_OR_POP chains
- Extract multiple patterns into single case
Dependency: After pez-detect-and-extract-df2a61f4 (match guards)
Verify: Test with 'case 1 | 2 | 3:' pattern
