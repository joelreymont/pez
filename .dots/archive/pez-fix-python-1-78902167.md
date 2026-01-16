---
title: Fix Python 1.5-2.2 marshal parsing
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:56:50.735948+02:00\""
closed-at: "2026-01-16T06:57:03.103511+02:00"
---

src/pyc.zig:849-872 - Use 16-bit fields for argcount/nlocals/stacksize/flags in Python 1.5-2.2, currently reading 32-bit causes all 40+ files to output 'def (): pass'
