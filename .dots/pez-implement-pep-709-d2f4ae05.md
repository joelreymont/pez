---
title: Implement PEP 709 inline comprehensions
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:27.529778+02:00"
---

Detect and reconstruct list/set/dict/generator comprehensions from inline bytecode (Python 3.12+, no separate code object). Handle multiple for clauses, if clauses, async comprehensions. Files: src/comprehension.zig or src/decompile.zig. Dependencies: none. Verify: 3.12+ comprehension tests pass.
