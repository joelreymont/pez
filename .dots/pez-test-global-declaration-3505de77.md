---
title: Test global declaration fix
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:11.462353+02:00"
---

File: refs/pycdc/tests/compiled/test_class_method_py3.3.7.pyc
Run pez and verify:
- No spurious 'global print' declarations
- Only STORE_GLOBAL generates global statements
- Compare output to pycdc
Dependencies: pez-remove-load-global-7a2f8dfe
Verify: ./zig-out/bin/pez refs/pycdc/tests/compiled/test_class_method_py3.3.7.pyc | grep -v 'global print'
