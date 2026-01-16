---
title: Create match guard test suite
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:47:45.066621+02:00"
---

test/corpus_src/match_guards.py: Comprehensive guard tests.
- guard_simple: 'case n if n < 0'
- guard_sequence: 'case [a, b] if a < b'
- guard_mapping: 'case {"val": v} if v > 0'
- guard_complex: multiple patterns with guards
- Compile with python3: py_compile.compile()
- Verify: ./zig-out/bin/pez test/corpus/match_guards.3.14.pyc
