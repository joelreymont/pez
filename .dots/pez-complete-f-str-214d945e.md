---
title: Complete f-string support
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:28.448288+02:00"
---

Implement FORMAT_VALUE, BUILD_STRING handlers. Reconstruct format specs, nested f-strings, conversion flags (\!s/\!r/\!a), debug f-strings (f'{x=}'). Handle PEP 701 (3.12+). Files: src/fstring.zig or src/expression.zig. Dependencies: none. Verify: 3.6+ f-string tests pass.
