---
title: Emit except* in codegen
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:46:55.854772+02:00"
---

src/codegen.zig: Emit 'except* Type as e:' syntax.
- Check ExceptHandler.is_star flag
- If true: emit 'except*' instead of 'except'
- Depends: is_star field, except* detection
- Verify: ./zig-out/bin/pez test/corpus/pep_654_exception_groups.3.14.pyc | grep 'except\*'
