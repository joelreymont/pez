---
title: Run full pycdc test suite
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:56.008999+02:00"
---

File: refs/pycdc/tests/compiled/*.pyc
Run pez on all 190 .pyc files:
  for f in refs/pycdc/tests/compiled/*.pyc; do ./zig-out/bin/pez "$f" 2>&1; done
Count errors: should be 0 hard failures
Compare outputs with pycdc where possible
Dependencies: pez-test-python-1-f5c32691, pez-test-build-const-bc150e01, pez-test-python-2-aafd0859, pez-test-global-declaration-3505de77, pez-test-exc-handler-3ffe0722, pez-test-match-guard-1898a610
Verify: grep -c 'error:' and check for 0
