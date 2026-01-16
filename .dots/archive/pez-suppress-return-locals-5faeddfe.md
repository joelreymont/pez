---
title: Suppress return locals() in Python 2.x classes
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:06:53.394284+02:00\""
closed-at: "2026-01-16T10:18:07.814864+02:00"
---

Python 2.x class bodies end with LOAD_LOCALS + RETURN_VALUE.
Affected files: test_class.2.5.pyc, test_docstring.2.5.pyc
Bug: Output shows 'return locals()' at end of each class.
Fix: In src/decompile.zig, detect this pattern and suppress the return statement.
Only for class code objects (flags & 0x02 = newlocals, typically 0x42).
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/test_class.2.5.pyc should not have 'return locals()'
