---
title: Build roundtrip test framework
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T09:29:25.078383+02:00\""
closed-at: "2026-01-16T10:16:46.096246+02:00"
---

Implement decompile → recompile → compare pipeline. Compare all code object fields (co_code despecialized, co_consts, co_names, co_varnames/localsplusnames, co_freevars, co_cellvars, co_argcount, co_flags, exception/line tables normalized, CFG). Files: new test/roundtrip.zig or similar. Dependencies: despecialization dot. Verify: roundtrip test passes for simple .pyc.
