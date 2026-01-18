---
title: Fix debug_dump Zig 0.15 build
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-18T07:30:34.585650+02:00\""
closed-at: "2026-01-18T07:53:28.302091+02:00"
close-reason: completed
---

Full context: zig build fails in src/debug_dump.zig (json stringify API, constness, analyzer mut, toOwnedSlice type). Errors at lines ~75,114,158,267,300. Root cause: Zig 0.15 API changes and const mismatch. Fix: use std.json.stringifyAlloc/Writer or std.json.stringify; adjust deinit signatures to take *const or @constCast; change buildPatternDump to accept *const Analyzer or pass mutable; fix collectChildren return type and slice constness. Why: restore pez build.
