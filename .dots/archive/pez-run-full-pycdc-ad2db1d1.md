---
title: Run full pycdc test suite
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:29:22.184172+02:00\""
closed-at: "2026-01-16T10:18:07.847077+02:00"
---

Depends: pez-test-all-python-d3c059db, pez-fix-exc-handler-6885658d, pez-fix-build-const-2a9cb272, pez-suppress-return-locals-69ee766d, pez-remove-load-global-ee42e64b
Command: for f in refs/pycdc/tests/compiled/*.pyc; do ./zig-out/bin/pez "$f" 2>&1; done | grep -c 'error:'
Target: 0 errors (190/190 passing)
Verify: Compare sample outputs with pycdc
