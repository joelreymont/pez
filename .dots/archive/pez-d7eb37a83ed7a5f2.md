---
title: Parse TYPE_FLOAT
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-07T17:37:04.779860+02:00\""
closed-at: "2026-01-08T06:34:54.285911+02:00"
---

File: src/pyc.zig - Add TYPE_FLOAT ('f') parsing: read 1-byte length, then ASCII float string. Convert to f64 using std.fmt.parseFloat.
