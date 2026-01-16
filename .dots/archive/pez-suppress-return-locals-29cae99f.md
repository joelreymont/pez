---
title: "Suppress 'return locals()' in Py2 classes"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:56:51.349103+02:00\""
closed-at: "2026-01-16T06:57:42.259087+02:00"
---

src/decompile.zig - Detect LOAD_LOCALS + RETURN_VALUE at end of class body (flags 0x42), suppress output
