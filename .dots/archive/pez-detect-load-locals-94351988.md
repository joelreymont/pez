---
title: Detect LOAD_LOCALS + RETURN_VALUE pattern
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-15T18:10:53.055289+02:00\""
closed-at: "2026-01-16T10:18:07.798441+02:00"
blocks:
  - pez-suppress-return-locals-5faeddfe
---

In src/decompile.zig or src/stack.zig, detect when:
1. LOAD_LOCALS instruction
2. Immediately followed by RETURN_VALUE
3. In a class body (code flags & 0x02 = newlocals)
Mark this as 'class namespace return' - don't emit statement.
