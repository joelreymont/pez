---
title: Add PEP 552 .pyc header parsing
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T09:29:24.161016+02:00\""
closed-at: "2026-01-16T10:16:12.033525+02:00"
---

Implement Python 3.7+ .pyc header parsing: flags (hash-based/checked/unchecked), hash/timestamp, source size. Files: src/marshal.zig or wherever .pyc headers are parsed. Dependencies: none. Verify: roundtrip tests with 3.7+ .pyc files preserve header.
