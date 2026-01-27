---
title: pyc-tuple-ref-bytes
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T16:04:35.740328+01:00"
---

Full context: src/pyc.zig:1092-1108; cause: TYPE_REF tuple strings reject .bytes, breaking Python 2 name tuples referenced by TYPE_REF; fix: accept .bytes and .string, add marshal regression test.
