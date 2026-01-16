---
title: Test Python 2.x class output
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:01:56.479607+02:00"
---

File: refs/pycdc/tests/compiled/test_class.2.5.pyc
Run pez and verify:
- No 'return locals()' at end of class body
- Compare with test_docstring.2.5.pyc
- Compare output to pycdc
Dependencies: pez-suppress-return-locals-a11d49cf
Verify: ./zig-out/bin/pez refs/pycdc/tests/compiled/test_class.2.5.pyc
