---
title: Fix import group leak
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-17T20:04:38.720107+02:00\""
closed-at: "2026-01-17T20:04:49.720176+02:00"
close-reason: fixed
---

Full context: src/decompile.zig:9603, tryDecompileImportFromGroup allocated fromlist slice without freeing; fix by removing allocation and only validating tuple length to avoid leaks.
