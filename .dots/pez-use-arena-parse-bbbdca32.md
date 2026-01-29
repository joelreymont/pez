---
title: Use arena parse
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T17:55:13.552982+01:00"
---

Context: src/pyc.zig:720 and Module.deinit; cause: general allocator frees can corrupt on malformed/ref-heavy pyc; fix: back Module with ArenaAllocator and hard-fail on invalid pyc; deps: none; verification: zig test src/pyc.zig --test-filter "loadFromFile invalid pyc hard-fails"
