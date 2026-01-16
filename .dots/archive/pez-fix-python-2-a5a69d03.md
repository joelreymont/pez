---
title: Fix Python 2.2 varnames loading
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:28:44.434614+02:00\""
closed-at: "2026-01-16T10:17:14.263274+02:00"
---

Files: src/pyc.zig:915-919
Depends: pez-debug-python-2-ef1c9f28
Root cause from debug: likely varnames array order or empty
Fix: Verify readTupleStrings and marshal format for Python 2.2
Test: ./zig-out/bin/pez refs/pycdc/tests/compiled/if_elif_else.2.2.pyc succeeds
