---
title: Fix Python 1.5-2.2 16-bit field parsing
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T08:05:07.495137+02:00\""
closed-at: "2026-01-16T08:06:33.927287+02:00"
---

src/pyc.zig:849-872 - Add version checks to read argcount/nlocals/stacksize/flags as 16-bit for Python 1.5-2.2, handling 1.3-1.4 (no stacksize) and 1.0-1.2 (no argcount). Currently reads all as 32-bit causing garbage. Test: Python 1.x files should decompile, not output 'def (): pass'
