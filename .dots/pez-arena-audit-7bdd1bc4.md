---
title: Arena audit
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T12:12:28.350152+01:00"
---

Context: src/decompile.zig:346; cause: transient allocs use general allocator in hot paths; fix: route decompiler/sim/stack transient allocations through arena and reset per code object; deps: Capture failures; verification: zig build test + allocator stats show reduced allocs.
