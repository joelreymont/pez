---
title: "Verification: Run full pycdc test suite"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:23:51.730531+02:00\""
closed-at: "2026-01-16T10:18:07.833002+02:00"
---

Run: for f in refs/pycdc/tests/compiled/*.pyc; do ./zig-out/bin/pez "" 2>&1; done | grep -c 'error:' - Should be 0 (190/190 passing)
