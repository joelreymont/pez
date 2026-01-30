---
title: [HIGH] simopt-hard
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.494343+01:00"
---

Full context: src/decompile.zig:788-793; cause: simOpt masks soft errors by returning false; fix: require explicit handling or return error union; audit call sites.
