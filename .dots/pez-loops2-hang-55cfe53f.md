---
title: Loops2 hang
status: open
priority: 1
issue-type: task
created-at: "2026-02-02T18:04:56.213461+01:00"
---

Context: src/decompile.zig:25690 loops2 2.2 fixture; cause: loop analysis/CFG traversal can spin on 2.2 bytecode; fix: trace loop detection and terminate on stable fixpoint; verification: zig build test -Dtest-filter='loops2 decompile frees allocations' + timeout 20 ./zig-out/bin/pez refs/pycdc/tests/compiled/test_loops2.2.2.pyc.
