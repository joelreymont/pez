---
title: Listcomp invalid free
status: open
priority: 1
issue-type: task
created-at: "2026-02-02T18:04:52.101913+01:00"
---

Context: src/decompile.zig:25683 listComprehensions 2.7 fixture; cause: allocator ownership mismatch in listcomp/comp_builder teardown; fix: audit comp/listcomp deinit paths and ensure arena-only frees; verification: zig build test -Dtest-filter='list comprehension decompile frees allocations' + CLI run on refs/pycdc/tests/compiled/test_listComprehensions.2.7.pyc without invalid free.
