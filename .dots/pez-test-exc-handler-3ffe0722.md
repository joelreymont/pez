---
title: Test exception handler fix
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:28.662978+02:00"
---

File: refs/pycdc/tests/compiled/try_except_finally.2.6.pyc and async_for.3.7.pyc
Run pez and verify:
- No StackUnderflow at offset 30 (try_except_finally)
- No StackUnderflow at offset 112 (async_for)
- DUP_TOP succeeds with exception values on stack
Dependencies: pez-init-handler-stack-6d06d5fc
Verify: ./zig-out/bin/pez refs/pycdc/tests/compiled/try_except_finally.2.6.pyc && ./zig-out/bin/pez refs/pycdc/tests/compiled/async_for.3.7.pyc
