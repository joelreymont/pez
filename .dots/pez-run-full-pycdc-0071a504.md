---
title: Run full pycdc test suite
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:05:11.163995+02:00"
---

After all fixes, verify 190/190 files parse: for f in refs/pycdc/tests/compiled/*.pyc; do ./zig-out/bin/pez "" 2>&1; done | grep -c 'error:' should be 0. Compare output semantics with pycdc where possible
